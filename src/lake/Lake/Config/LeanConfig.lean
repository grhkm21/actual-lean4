/-
Copyright (c) 2022 Mac Malone. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Mac Malone
-/
namespace Lake

/--
Lake equivalent of CMake's
[`CMAKE_BUILD_TYPE`](https://stackoverflow.com/a/59314670).
-/
inductive BuildType
  /--
  Debug optimization, asserts enabled, custom debug code enabled, and
  debug info included in executable (so you can step through the code with a
  debugger and have address to source-file:line-number translation).
  For example, passes `-Og -g` when compiling C code.
  -/
  | debug
  /--
  Optimized, *with* debug info, but no debug code or asserts
  (e.g., passes `-O3 -g -DNDEBUG` when compiling C code).
  -/
  | relWithDebInfo
  /--
  Same as `release` but optimizing for size rather than speed
  (e.g., passes `-Os -DNDEBUG` when compiling C code).
  -/
  | minSizeRel
  /--
  High optimization level and no debug info, code, or asserts
  (e.g., passes `-O3 -DNDEBUG` when compiling C code).
  -/
  | release
deriving Inhabited, Repr, DecidableEq, Ord

instance : LT BuildType := ltOfOrd
instance : LE BuildType := leOfOrd
instance : Min BuildType := minOfLe
instance : Max BuildType := maxOfLe

/-- The arguments to pass to `leanc` based on the build type. -/
def BuildType.leancArgs : BuildType → Array String
| debug => #["-Og", "-g"]
| relWithDebInfo => #["-O3", "-g", "-DNDEBUG"]
| minSizeRel => #["-Os", "-DNDEBUG"]
| release => #["-O3", "-DNDEBUG"]

/-- Configuration options common to targets that build modules. -/
structure LeanConfig where
  /--
  The mode in which the modules should be built (e.g., `debug`, `release`).
  Defaults to `release`.
  -/
  buildType : BuildType := .release
  /--
  Additional arguments to pass to `lean`
  when compiling a module's Lean source files.
  -/
  moreLeanArgs : Array String := #[]
  /--
  Additional arguments to pass to `lean`
  when compiling a module's Lean source files.

  Unlike `moreLeanArgs`, these arguments do not affect the trace
  of the build result, so they can be changed without triggering a rebuild.
  They come *before* `moreLeanArgs`.
  -/
  weakLeanArgs : Array String := #[]
  /--
  Additional arguments to pass to `leanc`
  when compiling a module's C source files generated by `lean`.

  Lake already passes some flags based on the `buildType`,
  but you can change this by, for example, adding `-O0` and `-UNDEBUG`.
  -/
  moreLeancArgs : Array String := #[]
  /--
  Additional arguments to pass to `leanc`
  when compiling a module's C source files generated by `lean`.

  Unlike `moreLeancArgs`, these arguments do not affect the trace
  of the build result, so they can be changed without triggering a rebuild.
  They come *before* `moreLeancArgs`.
  -/
  weakLeancArgs : Array String := #[]
  /--
  Additional arguments to pass to `leanc` when linking (e.g., for shared
  libraries or binary executables). These will come *after* the paths of
  external libraries.
  -/
  moreLinkArgs : Array String := #[]
  /--
  Additional arguments to pass to `leanc` when linking (e.g., for shared
  libraries or binary executables). These will come *after* the paths of
  external libraries.

  Unlike `moreLinkArgs`, these arguments do not affect the trace
  of the build result, so they can be changed without triggering a rebuild.
  They come *before* `moreLinkArgs`.
  -/
  weakLinkArgs : Array String := #[]
deriving Inhabited, Repr
