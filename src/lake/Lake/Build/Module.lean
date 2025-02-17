/-
Copyright (c) 2021 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Sebastian Ullrich, Mac Malone
-/
import Lake.Util.OrdHashSet
import Lake.Util.List
import Lean.Elab.ParseImportsFast
import Lake.Build.Common

/-! # Module Facet Builds
Build function definitions for a module's builtin facets.
-/

open System

namespace Lake

/-- Compute library directories and build external library Jobs of the given packages. -/
def recBuildExternDynlibs (pkgs : Array Package)
: IndexBuildM (Array (BuildJob Dynlib) × Array FilePath) := do
  let mut libDirs := #[]
  let mut jobs : Array (BuildJob Dynlib) := #[]
  for pkg in pkgs do
    libDirs := libDirs.push pkg.nativeLibDir
    jobs := jobs.append <| ← pkg.externLibs.mapM (·.dynlib.fetch)
  return (jobs, libDirs)

/--
Build the dynlibs of the transitive imports that want precompilation
and the dynlibs of *their* imports.
-/
partial def recBuildPrecompileDynlibs (imports : Array Module)
: IndexBuildM (Array (BuildJob Dynlib) × Array (BuildJob Dynlib) × Array FilePath) := do
  let (pkgs, _, jobs) ←
    go imports OrdPackageSet.empty ModuleSet.empty #[] false
  return (jobs, ← recBuildExternDynlibs pkgs.toArray)
where
  go imports pkgs modSet jobs shouldPrecompile := do
    let mut pkgs := pkgs
    let mut modSet := modSet
    let mut jobs := jobs
    for mod in imports do
      if modSet.contains mod then
        continue
      modSet := modSet.insert mod
      let shouldPrecompile := shouldPrecompile || mod.shouldPrecompile
      if shouldPrecompile then
        pkgs := pkgs.insert mod.pkg
        jobs := jobs.push <| (←  mod.dynlib.fetch)
      let recImports ← mod.imports.fetch
      (pkgs, modSet, jobs) ← go recImports pkgs modSet jobs shouldPrecompile
    return (pkgs, modSet, jobs)

variable [MonadLiftT BuildM m]

/--
Recursively parse the Lean files of a module and its imports
building an `Array` product of its direct local imports.
-/
def Module.recParseImports (mod : Module) : IndexBuildM (Array Module) := do
  let callstack : CallStack BuildKey ← EquipT.lift <| CycleT.readCallStack
  let contents ← liftM <| tryCatch (IO.FS.readFile mod.leanFile) fun err =>
    -- filter out only modules from build key, and remove adjacent duplicates (squeeze),
    -- since Lake visits multiple nested facets of the same module.
    let callstack := callstack.filterMap (fun bk =>
      match bk with
      | .moduleFacet mod .. => .some s!"'{mod.toString}'"
      | _ => .none
    ) |> List.squeeze
    let breadcrumb := String.intercalate " ▸ " callstack.reverse
    error s!"{breadcrumb}: {err}"
  let imports ← Lean.parseImports' contents mod.leanFile.toString
  let mods ← imports.foldlM (init := OrdModuleSet.empty) fun set imp =>
    findModule? imp.module <&> fun | some mod => set.insert mod | none => set
  return mods.toArray

/-- The `ModuleFacetConfig` for the builtin `importsFacet`. -/
def Module.importsFacetConfig : ModuleFacetConfig importsFacet :=
  mkFacetConfig (·.recParseImports)

/-- Recursively compute a module's transitive imports. -/
def Module.recComputeTransImports (mod : Module) : IndexBuildM (Array Module) := do
  (·.toArray) <$> (← mod.imports.fetch).foldlM (init := OrdModuleSet.empty) fun set imp => do
    return set.appendArray (← imp.transImports.fetch) |>.insert imp

/-- The `ModuleFacetConfig` for the builtin `transImportsFacet`. -/
def Module.transImportsFacetConfig : ModuleFacetConfig transImportsFacet :=
  mkFacetConfig (·.recComputeTransImports)

/-- Recursively compute a module's precompiled imports. -/
def Module.recComputePrecompileImports (mod : Module) : IndexBuildM (Array Module) := do
  (·.toArray) <$> (← mod.imports.fetch).foldlM (init := OrdModuleSet.empty) fun set imp => do
    if imp.shouldPrecompile then
      return set.appendArray (← imp.transImports.fetch) |>.insert imp
    else
      return set.appendArray (← imp.precompileImports.fetch)

/-- The `ModuleFacetConfig` for the builtin `precompileImportsFacet`. -/
def Module.precompileImportsFacetConfig : ModuleFacetConfig precompileImportsFacet :=
  mkFacetConfig (·.recComputePrecompileImports)

/--
Recursively build a module's dependencies, including:
* Transitive local imports
* Shared libraries (e.g., `extern_lib` targets or precompiled modules)
* `extraDepTargets` of its library
-/
def Module.recBuildDeps (mod : Module) : IndexBuildM (BuildJob (SearchPath × Array FilePath)) := do
  let imports ← mod.imports.fetch
  let extraDepJob ← mod.lib.extraDep.fetch
  let precompileImports ← mod.precompileImports.fetch
  let modJobs ← precompileImports.mapM (·.dynlib.fetch)
  let pkgs := precompileImports.foldl (·.insert ·.pkg)
    OrdPackageSet.empty |>.insert mod.pkg |>.toArray
  let (externJobs, libDirs) ← recBuildExternDynlibs pkgs
  let importJob ← BuildJob.mixArray <| ← imports.mapM (·.olean.fetch)
  let externDynlibsJob ← BuildJob.collectArray externJobs
  let modDynlibsJob ← BuildJob.collectArray modJobs

  extraDepJob.bindAsync fun _ extraDepTrace => do
  importJob.bindAsync fun _ importTrace => do
  modDynlibsJob.bindAsync fun modDynlibs modTrace => do
  return externDynlibsJob.mapWithTrace fun externDynlibs externTrace =>
    let depTrace := extraDepTrace.mix <| importTrace.mix <| modTrace.mix externTrace
    /-
    Requirements:
    * Lean wants the external library symbols before module symbols.
    * Unix requires the file extension of the dynlib.
    * For some reason, building from the Lean server requires full paths.
      Everything else loads fine with just the augmented library path.
    * Linux needs the augmented path to resolve nested dependencies in dynlibs.
    -/
    let dynlibPath := libDirs ++ externDynlibs.filterMap (·.dir?) |>.toList
    let dynlibs := externDynlibs.map (·.path) ++ modDynlibs.map (·.path)
    ((dynlibPath, dynlibs), depTrace)

/-- The `ModuleFacetConfig` for the builtin `depsFacet`. -/
def Module.depsFacetConfig : ModuleFacetConfig depsFacet :=
  mkFacetJobConfigSmall (·.recBuildDeps)

/--
Recursively build a Lean module.
Fetch its dependencies and then elaborate the Lean source file, producing
all possible artifacts (i.e., `.olean`, `ilean`, and `.c`).
-/
def Module.recBuildLean (mod : Module) : IndexBuildM (BuildJob Unit) := do
  (← mod.deps.fetch).bindSync fun (dynlibPath, dynlibs) depTrace => do
    let argTrace : BuildTrace := pureHash mod.leanArgs
    let srcTrace : BuildTrace ← computeTrace { path := mod.leanFile : TextFilePath }
    let modTrace := (← getLeanTrace).mix <| argTrace.mix <| srcTrace.mix depTrace
    buildUnlessUpToDate mod modTrace mod.traceFile do
      compileLeanModule mod.name.toString mod.leanFile mod.oleanFile mod.ileanFile mod.cFile
        (← getLeanPath) mod.rootDir dynlibs dynlibPath (mod.weakLeanArgs ++ mod.leanArgs) (← getLean)
      discard <| cacheFileHash mod.oleanFile
      discard <| cacheFileHash mod.ileanFile
      discard <| cacheFileHash mod.cFile
    return ((), depTrace)

/-- The `ModuleFacetConfig` for the builtin `leanArtsFacet`. -/
def Module.leanArtsFacetConfig : ModuleFacetConfig leanArtsFacet :=
  mkFacetJobConfig (·.recBuildLean)

/-- The `ModuleFacetConfig` for the builtin `oleanFacet`. -/
def Module.oleanFacetConfig : ModuleFacetConfig oleanFacet :=
  mkFacetJobConfigSmall fun mod => do
    (← mod.leanArts.fetch).bindSync fun _ depTrace =>
      return (mod.oleanFile, mixTrace (← fetchFileTrace mod.oleanFile) depTrace)

/-- The `ModuleFacetConfig` for the builtin `ileanFacet`. -/
def Module.ileanFacetConfig : ModuleFacetConfig ileanFacet :=
  mkFacetJobConfigSmall fun mod => do
    (← mod.leanArts.fetch).bindSync fun _ depTrace =>
      return (mod.ileanFile, mixTrace (← fetchFileTrace mod.ileanFile) depTrace)

/-- The `ModuleFacetConfig` for the builtin `cFacet`. -/
def Module.cFacetConfig : ModuleFacetConfig cFacet :=
  mkFacetJobConfigSmall fun mod => do
    (← mod.leanArts.fetch).bindSync fun _ _ =>
      -- do content-aware hashing so that we avoid recompiling unchanged C files
      return (mod.cFile, ← fetchFileTrace mod.cFile)

/-- Recursively build the module's object file from its C file produced by `lean`. -/
def Module.recBuildLeanO (self : Module) : IndexBuildM (BuildJob FilePath) := do
  buildLeanO self.name.toString self.oFile (← self.c.fetch) self.weakLeancArgs self.leancArgs

/-- The `ModuleFacetConfig` for the builtin `oFacet`. -/
def Module.oFacetConfig : ModuleFacetConfig oFacet :=
  mkFacetJobConfig Module.recBuildLeanO

-- TODO: Return `BuildJob OrdModuleSet × OrdPackageSet` or `OrdRBSet Dynlib`
/-- Recursively build the shared library of a module (e.g., for `--load-dynlib`). -/
def Module.recBuildDynlib (mod : Module) : IndexBuildM (BuildJob Dynlib) := do

  -- Compute dependencies
  let transImports ← mod.transImports.fetch
  let modJobs ← transImports.mapM (·.dynlib.fetch)
  let pkgs := transImports.foldl (·.insert ·.pkg)
    OrdPackageSet.empty |>.insert mod.pkg |>.toArray
  let (externJobs, pkgLibDirs) ← recBuildExternDynlibs pkgs
  let linkJobs ← mod.nativeFacets.mapM (fetch <| mod.facet ·.name)

  -- Collect Jobs
  let linksJob ← BuildJob.collectArray linkJobs
  let modDynlibsJob ← BuildJob.collectArray modJobs
  let externDynlibsJob ← BuildJob.collectArray externJobs

  -- Build dynlib
  show SchedulerM _ from do
    linksJob.bindAsync fun links linksTrace => do
    modDynlibsJob.bindAsync fun modDynlibs modLibsTrace => do
    externDynlibsJob.bindSync fun externDynlibs externLibsTrace => do
      let libNames := modDynlibs.map (·.name) ++ externDynlibs.map (·.name)
      let libDirs := pkgLibDirs ++ externDynlibs.filterMap (·.dir?)
      let depTrace := linksTrace.mix <| modLibsTrace.mix <| externLibsTrace.mix
        <| (← getLeanTrace).mix <| ← computeHash mod.linkArgs
      let trace ← buildFileUnlessUpToDate mod.dynlibFile depTrace do
        let args :=
          links.map toString ++
          libDirs.map (s!"-L{·}") ++ libNames.map (s!"-l{·}") ++
          mod.weakLinkArgs ++ mod.linkArgs
        compileSharedLib mod.name.toString mod.dynlibFile args (← getLeanc)
      return (⟨mod.dynlibFile, mod.dynlibName⟩, trace)

/-- The `ModuleFacetConfig` for the builtin `dynlibFacet`. -/
def Module.dynlibFacetConfig : ModuleFacetConfig dynlibFacet :=
  mkFacetJobConfig Module.recBuildDynlib

open Module in
/--
A name-configuration map for the initial set of
Lake module facets (e.g., `lean.{imports, c, o, dynlib]`).
-/
def initModuleFacetConfigs : DNameMap ModuleFacetConfig :=
  DNameMap.empty
  |>.insert importsFacet importsFacetConfig
  |>.insert transImportsFacet transImportsFacetConfig
  |>.insert precompileImportsFacet precompileImportsFacetConfig
  |>.insert depsFacet depsFacetConfig
  |>.insert leanArtsFacet leanArtsFacetConfig
  |>.insert oleanFacet oleanFacetConfig
  |>.insert ileanFacet ileanFacetConfig
  |>.insert cFacet cFacetConfig
  |>.insert oFacet oFacetConfig
  |>.insert dynlibFacet dynlibFacetConfig
