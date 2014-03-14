--
-- Parser.y --- Happy parser for the Lobster language.
--
-- Copyright (C) 2014, Galois, Inc.
-- All Rights Reserved.
--

{
module Lobster.Core.Parser
  ( parsePolicy
  ) where

import Lobster.Core.AST
import Lobster.Core.Lexer
import Lobster.Core.Error

import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as T
}

%name parsePolicy Policy
%tokentype { Token }

%token
  'bidirectional'   { Token _ _ (TokKeyword KwBidirectional) }
  'class'           { Token _ _ (TokKeyword KwClass) }
  'domain'          { Token _ _ (TokKeyword KwDomain) }
  'input'           { Token _ _ (TokKeyword KwInput) }
  'object'          { Token _ _ (TokKeyword KwObject) }
  'output'          { Token _ _ (TokKeyword KwOutput) }
  'port'            { Token _ _ (TokKeyword KwPort) }
  'subject'         { Token _ _ (TokKeyword KwSubject) }
--  'assert'          { Token _ _ (TokKeyword KwAssert) }
--  'exists'          { Token _ _ (TokKeyword KwExists) }
--  'never'           { Token _ _ (TokKeyword KwNever) }
--  'this'            { Token _ _ (TokKeyword KwThis) }

  '('               { Token _ _ (TokOperator OpLParen) }
  ')'               { Token _ _ (TokOperator OpRParen) }
  '{'               { Token _ _ (TokOperator OpLBrace) }
  '}'               { Token _ _ (TokOperator OpRBrace) }
  '['               { Token _ _ (TokOperator OpLBracket) }
  ']'               { Token _ _ (TokOperator OpRBracket) }
  ';'               { Token _ _ (TokOperator OpSemi) }
  ','               { Token _ _ (TokOperator OpComma) }
  '='               { Token _ _ (TokOperator OpEquals) }
  ':'               { Token _ _ (TokOperator OpColon) }
  '.'               { Token _ _ (TokOperator OpPeriod) }
  '*'               { Token _ _ (TokOperator OpStar) }
--  '->'              { Token _ _ (TokOperator OpRArrow) }
--  '::'              { Token _ _ (TokOperator OpDoubleColon) }
--  '.*'              { Token _ _ (TokOperator OpDotStar) }

  '-->'             { Token _ _ (TokConnOperator OpConnLeftToRight) }
  '<--'             { Token _ _ (TokConnOperator OpConnRightToLeft) }
  '<-->'            { Token _ _ (TokConnOperator OpConnBidirectional) }
  '--'              { Token _ _ (TokConnOperator OpConnNeutral) }

  Integer           { Token _ _ (TokInteger _) }
  String            { Token _ _ TokString }
  UIdent            { Token _ _ TokUIdent }
  LIdent            { Token _ _ TokLIdent }
  EOF               { Token _ _ TokEOF }

%monad { Alex }
%lexer { lexwrap } { Token _ _ TokEOF }
%error { happyError }

%%

----------------------------------------------------------------------
-- Atoms

-- An integer literal.
LitInteger :: { LitInteger Span }
LitInteger
  : Integer         { LitInteger (tokSpan $1) (tokIntValue $1) }

-- A string literal.
LitString :: { LitString Span }
LitString
  -- XXX shouldn't use "read" here...
  : String          { LitString (tokSpan $1) (read $ T.unpack $ tokText $1) }

-- A direction literal keyword.
LitDirection :: { LitDirection Span }
LitDirection
  : 'input'         { LitDirection (tokSpan $1) DirInput }
  | 'output'        { LitDirection (tokSpan $1) DirOutput }
  | 'bidirectional' { LitDirection (tokSpan $1) DirBidirectional }

-- A position literal keyword.
LitPosition :: { LitPosition Span }
LitPosition
  : 'subject'       { LitPosition (tokSpan $1) PosSubject }
  | 'object'        { LitPosition (tokSpan $1) PosObject }

-- A variable name (starts with a lower case letter).
VarName :: { VarName Span }
VarName 
  : LIdent { VarName (tokSpan $1) (tokText $1) }

-- A comma separated list of zero or more variable names.
VarNameList :: { [VarName Span] }
VarNameList
  : {- empty -} { [] }
  | VarName { (:[]) $1 }
  | VarName ',' VarNameList { (:) $1 $3 }

-- A type name (starts with an upper case letter).
TypeName :: { TypeName Span }
TypeName
  : UIdent { TypeName (tokSpan $1) (tokText $1) }

-- A connection operator.
ConnOp :: { ConnOp Span }
ConnOp
  : '-->'   { ConnOp (tokSpan $1) ConnLeftToRight }
  | '<--'   { ConnOp (tokSpan $1) ConnRightToLeft }
  | '<-->'  { ConnOp (tokSpan $1) ConnBidirectional }
  | '--'    { ConnOp (tokSpan $1) ConnNeutral }

----------------------------------------------------------------------
-- Port Type Definition

PortAttr :: { PortAttr Span }
PortAttr
  : VarName '=' MaybeExp
    { PortAttr $1 $3 }

PortAttrList :: { [PortAttr Span] }
PortAttrList
  : {- empty -} { [] }
  | PortAttr { (:[]) $1 }
  | PortAttr ',' PortAttrList { (:) $1 $3 }

PortType :: { [PortAttr Span] }
PortType
  : {- empty -} { [] }
  | ':' '{' PortAttrList '}' { $3 }

----------------------------------------------------------------------
-- Annotations

AnnotationElement :: { AnnotationElement Span }
AnnotationElement
  : TypeName '(' ExpList ')' { ($1, $3) }

AnnotationElementList :: { [AnnotationElement Span] }
AnnotationElementList
  : {- empty -} { [] }
  | AnnotationElement { (:[]) $1 }
  | AnnotationElement ',' AnnotationElementList { (:) $1 $3 }

Annotation :: { Annotation Span }
Annotation
  : AnnotationElementList { Annotation $1 }

----------------------------------------------------------------------
-- Statements

Policy :: { Policy Span }
Policy : StmtList { Policy (foldr unionSpan emptySpan (map label $1)) $1 }

-- Parse a port identifier.
PortName :: { PortName Span }
PortName
  : VarName { UPortName $1 }
  | VarName '.' VarName { QPortName (unionSpan (label $1) (label $3)) $1 $3 }

-- A statement at top level or within a class.
Stmt :: { Stmt Span }
Stmt
  : 'class' TypeName '(' VarNameList ')' '{' StmtList '}'
    { StmtClassDecl (spanToks $1 $8) $2 $4 $7 }
  | 'port' VarName PortType ';'
    { StmtPortDecl (spanToks $1 $4) $2 $3 }
  | 'domain' VarName '=' TypeName '(' ExpList ')' ';'
    { StmtDomainDecl (spanToks $1 $8) $2 $4 $6 }
  | VarName '=' Exp ';'
    { StmtAssign (unionSpan (label $1) (tokSpan $4)) $1 $3 }
  | PortName ConnOp PortName ';'
    { StmtConnection (unionSpan (label $1) (tokSpan $4)) $1 $2 $3 }
  | '[' Annotation ']' Stmt
    { StmtAnnotation (unionSpan (tokSpan $1) (label $4)) $2 $4 }

-- TODO: handle assertion statements

-- A backwards list of statements (0 or more).
StmtList_rev :: { [Stmt Span] }
StmtList_rev
  : {- empty -} { [] }
  | StmtList_rev Stmt { flip (:) $1 $2 }

-- A list of statements (0 or more).
StmtList :: { [Stmt Span] }
StmtList
  : StmtList_rev { reverse $1 }

----------------------------------------------------------------------
-- Expressions

-- An expression.
Exp :: { Exp Span }
Exp
  : LitInteger    { ExpInt $1 }
  | LitString     { ExpString $1 }
  | LitDirection  { ExpDirection $1 }
  | LitPosition   { ExpPosition $1 }
  | VarName       { ExpVar $1 }
  | '(' Exp ')'   { ExpParen (spanToks $1 $3) $2 }

-- An expression or '*' for no value.
MaybeExp :: { Maybe (Exp Span) }
MaybeExp
  : '*' { Nothing }
  | Exp { Just $1 }

-- A comma-separated list of expressions (0 or more).
ExpList :: { [Exp Span] }
ExpList
  : {- empty -} { [] }
  | Exp { (:[]) $1 }
  | Exp ',' ExpList { (:) $1 $3 }

----------------------------------------------------------------------
-- Assertions

-- TODO: Implement parser for assertion language.

{
lexwrap :: (Token -> Alex a) -> Alex a
lexwrap = (alexMonadScan >>=)

-- | Get the value of an integer token (partial).
tokIntValue :: Token -> Integer
tokIntValue (Token _ _ (TokInteger i)) = i
tokIntValue _ = error "not an integer token"

-- | Take the union span of two tokens.
spanToks :: Token -> Token -> Span
spanToks t1 t2 = unionSpan (tokSpan t1) (tokSpan t2)

happyError :: Token -> Alex a
happyError t = alexError $ ParseError (tokSpan t) msg
  where
    msg = T.pack ("syntax error at '" ++ T.unpack (tokText t) ++ "'")
}

-- vim: set ft=happy ts=2 et: