/-
Copyright (c) 2019 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura, Sebastian Ullrich
-/
import Lean.Parser.Basic
import Lean.Parser.Level
import Lean.Parser.Term
import Lean.Parser.Tactic
import Lean.Parser.Command
import Lean.Parser.Module
import Lean.Parser.Syntax
import Lean.Parser.Do

namespace Lean
namespace Parser

builtin_initialize
  registerAlias "ws" checkWsBefore
  registerAlias "noWs" checkNoWsBefore
  registerAlias "num" numLit
  registerAlias "str" strLit
  registerAlias "char" charLit
  registerAlias "name" nameLit
  registerAlias "ident" ident
  registerAlias "colGt" checkColGt
  registerAlias "colGe" checkColGe
  registerAlias "lookahead" lookahead
  registerAlias "atomic" atomic
  registerAlias "many" many
  registerAlias "many1" many1
  registerAlias "notFollowedBy" (notFollowedBy · "element")
  registerAlias "optional" optional
  registerAlias "withPosition" withPosition
  registerAlias "interpolatedStr" interpolatedStr
  registerAlias "orelse" orelse
  registerAlias "andthen" andthen

end Parser

namespace PrettyPrinter
namespace Parenthesizer

-- Close the mutual recursion loop; see corresponding `[extern]` in the parenthesizer.
@[export lean_mk_antiquot_parenthesizer]
def mkAntiquot.parenthesizer (name : String) (kind : Option SyntaxNodeKind) (anonymous := true) : Parenthesizer :=
  Parser.mkAntiquot.parenthesizer name kind anonymous

-- The parenthesizer auto-generated these instances correctly, but tagged them with the wrong kind, since the actual kind
-- (e.g. `ident`) is not equal to the parser name `Lean.Parser.Term.ident`.
@[builtinParenthesizer ident] def ident.parenthesizer : Parenthesizer := Parser.Term.ident.parenthesizer
@[builtinParenthesizer numLit] def numLit.parenthesizer : Parenthesizer := Parser.Term.num.parenthesizer
@[builtinParenthesizer scientificLit] def scientificLit.parenthesizer : Parenthesizer := Parser.Term.scientific.parenthesizer
@[builtinParenthesizer charLit] def charLit.parenthesizer : Parenthesizer := Parser.Term.char.parenthesizer
@[builtinParenthesizer strLit] def strLit.parenthesizer : Parenthesizer := Parser.Term.str.parenthesizer

open Lean.Parser

@[export lean_pretty_printer_parenthesizer_interpret_parser_descr]
unsafe def interpretParserDescr : ParserDescr → CoreM Parenthesizer
  | ParserDescr.const n                             => getConstAlias parenthesizerAliasesRef n
  | ParserDescr.unary n d                           => return (← getUnaryAlias parenthesizerAliasesRef n) (← interpretParserDescr d)
  | ParserDescr.binary n d₁ d₂                      => return (← getBinaryAlias parenthesizerAliasesRef n) (← interpretParserDescr d₁) (← interpretParserDescr d₂)
  | ParserDescr.node k prec d                       => return leadingNode.parenthesizer k prec (← interpretParserDescr d)
  | ParserDescr.nodeWithAntiquot _ k d              => return node.parenthesizer k (← interpretParserDescr d)
  | ParserDescr.sepBy p sep psep trail              => return sepBy.parenthesizer (← interpretParserDescr p) sep (← interpretParserDescr psep) trail
  | ParserDescr.sepBy1 p sep psep trail             => return sepBy1.parenthesizer (← interpretParserDescr p) sep (← interpretParserDescr psep) trail
  | ParserDescr.trailingNode k prec d               => return trailingNode.parenthesizer k prec (← interpretParserDescr d)
  | ParserDescr.symbol tk                           => return symbol.parenthesizer tk
  | ParserDescr.nonReservedSymbol tk includeIdent   => return nonReservedSymbol.parenthesizer tk includeIdent
  | ParserDescr.parser constName                    => combinatorParenthesizerAttribute.runDeclFor constName
  | ParserDescr.cat catName prec                    => return categoryParser.parenthesizer catName prec

end Parenthesizer

namespace Formatter

@[export lean_mk_antiquot_formatter]
def mkAntiquot.formatter (name : String) (kind : Option SyntaxNodeKind) (anonymous := true) : Formatter :=
  Parser.mkAntiquot.formatter name kind anonymous

@[builtinFormatter ident] def ident.formatter : Formatter := Parser.Term.ident.formatter
@[builtinFormatter numLit] def numLit.formatter : Formatter := Parser.Term.num.formatter
@[builtinFormatter scientificLit] def scientificLit.formatter : Formatter := Parser.Term.scientific.formatter
@[builtinFormatter charLit] def charLit.formatter : Formatter := Parser.Term.char.formatter
@[builtinFormatter strLit] def strLit.formatter : Formatter := Parser.Term.str.formatter

open Lean.Parser

@[export lean_pretty_printer_formatter_interpret_parser_descr]
unsafe def interpretParserDescr : ParserDescr → CoreM Formatter
  | ParserDescr.const n                             => getConstAlias formatterAliasesRef n
  | ParserDescr.unary n d                           => return (← getUnaryAlias formatterAliasesRef n) (← interpretParserDescr d)
  | ParserDescr.binary n d₁ d₂                      => return (← getBinaryAlias formatterAliasesRef n) (← interpretParserDescr d₁) (← interpretParserDescr d₂)
  | ParserDescr.node k prec d                       => return node.formatter k (← interpretParserDescr d)
  | ParserDescr.nodeWithAntiquot _ k d              => return node.formatter k (← interpretParserDescr d)
  | ParserDescr.sepBy p sep psep trail              => return sepBy.formatter (← interpretParserDescr p) sep (← interpretParserDescr psep) trail
  | ParserDescr.sepBy1 p sep psep trail             => return sepBy1.formatter (← interpretParserDescr p) sep (← interpretParserDescr psep) trail
  | ParserDescr.trailingNode k prec d               => return trailingNode.formatter k prec (← interpretParserDescr d)
  | ParserDescr.symbol tk                           => return symbol.formatter tk
  | ParserDescr.nonReservedSymbol tk includeIdent   => return nonReservedSymbol.formatter tk
  | ParserDescr.parser constName                    => combinatorFormatterAttribute.runDeclFor constName
  | ParserDescr.cat catName prec                    => return categoryParser.formatter catName

end Formatter
end PrettyPrinter
end Lean
