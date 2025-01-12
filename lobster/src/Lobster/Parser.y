-- A hand-modifiable parser for Lobster.
{
{-# OPTIONS_GHC -fno-warn-incomplete-patterns -fno-warn-overlapping-patterns #-}
module Lobster.Parser where

import Control.Error

import Lobster.AST
import Lobster.Lexer
import Lobster.Error

}

%name pPolicy Policy
%name pStatement Statement
%name pClassInstantiation ClassInstantiation
%name pConnRE ConnRE
%name pDomainSpec DomainSpec
%name pPortRE PortRE
%name pFlowPred FlowPred
%name pFlowRE FlowRE
%name pFlowRE0 FlowRE0
%name pPortDeclarationType PortDeclarationType
%name pPortDeclarationConnection PortDeclarationConnection
%name pExpression Expression
%name pDirection Direction
%name pPosition Position
%name pQualName QualName
%name pName Name
%name pPortTypeConstraint PortTypeConstraint
%name pNoneExpression NoneExpression
%name pConnection Connection
%name pIdentifier Identifier
%name pPortId PortId
%name pFlowId FlowId
%name pClassId ClassId
%name pListIdentifier ListIdentifier
%name pListExpression ListExpression
%name pListStatement ListStatement
%name pListPortTypeConstraint ListPortTypeConstraint

-- no lexer declaration
%monad { Err }
%tokentype { Token }

%token 
 '(' { PT _ (TS _ 1) }
 ')' { PT _ (TS _ 2) }
 '*' { PT _ (TS _ 3) }
 ',' { PT _ (TS _ 4) }
 '--' { PT _ (TS _ 5) }
 '-->' { PT _ (TS _ 6) }
 '->' { PT _ (TS _ 7) }
 '.' { PT _ (TS _ 8) }
 '.*' { PT _ (TS _ 9) }
 ':' { PT _ (TS _ 10) }
 '::' { PT _ (TS _ 11) }
 ';' { PT _ (TS _ 12) }
 '<--' { PT _ (TS _ 13) }
 '<-->' { PT _ (TS _ 14) }
 '=' { PT _ (TS _ 15) }
 '[' { PT _ (TS _ 16) }
 ']' { PT _ (TS _ 17) }
 'assert' { PT _ (TS _ 18) }
 'bidirectional' { PT _ (TS _ 19) }
 'class' { PT _ (TS _ 20) }
 'domain' { PT _ (TS _ 21) }
 'exists' { PT _ (TS _ 22) }
 'input' { PT _ (TS _ 23) }
 'never' { PT _ (TS _ 24) }
 'object' { PT _ (TS _ 25) }
 'output' { PT _ (TS _ 26) }
 'port' { PT _ (TS _ 27) }
 'subject' { PT _ (TS _ 28) }
 'this' { PT _ (TS _ 29) }
 '{' { PT _ (TS _ 30) }
 '}' { PT _ (TS _ 31) }

L_integ  { PT _ (TI $$) }
L_quoted { PT _ (TL $$) }
L_LIdent { PT _ (T_LIdent $$) }
L_UIdent { PT _ (T_UIdent $$) }
L_err    { _ }


%%

Integer :: { Integer } : L_integ  { (read ( $1)) :: Integer }
String  :: { String }  : L_quoted {  $1 }
LIdent    :: { LIdent} : L_LIdent { LIdent ($1)}
UIdent    :: { UIdent} : L_UIdent { UIdent ($1)}

Policy :: { Policy }
Policy : ListStatement { Policy (reverse $1) } 

AnnotationElement :: { AnnotationElement  }
AnnotationElement : UIdent '(' ListExpression ')' { ($1, $3) }

ListAnnotationElement :: { [AnnotationElement] }
ListAnnotationElement : {- empty -} { [] } 
  | AnnotationElement { (:[]) $1 }
  | AnnotationElement ',' ListAnnotationElement { (:) $1 $3 }

Annotation :: { Annotation }
Annotation : ListAnnotationElement { Annotation $1 }

Statement :: { Statement }
Statement
  : 'class' ClassId '(' ListIdentifier ')' '{' ListStatement '}'
    { annPos (tokenPosn $1) $ ClassDeclaration $2 $4 (reverse $7) }
  | 'port' PortId PortDeclarationType PortDeclarationConnection ';'
    { annPos (tokenPosn $1) $ PortDeclaration $2 $3 $4 }
  | 'domain' Identifier '=' ClassInstantiation ';'
    { annPos (tokenPosn $1) $ DomainDeclaration $2 $4 }
  | Identifier '=' Expression ';'
    -- XXX not ideal, would rather have start token
    { annPos (tokenPosn $2) $ Assignment $1 $3 }
  | ListExpression Connection ListExpression ';'
    -- XXX not ideal, would rather have start token
    { annPos (tokenPosn $4) $ PortConnection $1 $2 $3 }
  | 'assert' ConnRE '->' ConnRE '::' FlowPred ';'
    { annPos (tokenPosn $1) $ Assert $2 $4 $6 }
  | '[' Annotation ']' Statement
    { Annotated $2 $4 }

ClassInstantiation :: { ClassInstantiation }
ClassInstantiation : ClassId '(' ListExpression ')' { ClassInstantiation $1 $3 } 


ConnRE :: { ConnRE }
ConnRE : '[' DomainSpec PortRE ']' { ConnRE $2 $3 } 


DomainSpec :: { DomainSpec }
DomainSpec : 'this' { ThisDom } 
  | Identifier { IdentDom $1 }


PortRE :: { PortRE }
PortRE : '.*' { AnyPRE } 
  | '.' Identifier { IdPRE $2 }


FlowPred :: { FlowPred }
FlowPred : 'never' { NeverPathFP } 
  | 'exists' { ExistsPathFP }
  | FlowRE { PathFP $1 }


FlowRE :: { FlowRE }
FlowRE : FlowRE0 ConnRE FlowRE { ConsF $1 $2 $3 } 
  | FlowRE0 { $1 }


FlowRE0 :: { FlowRE }
FlowRE0 : '.*' { AnyFRE } 


PortDeclarationType :: { PortDeclarationType }
PortDeclarationType : {- empty -} { EmptyPDT } 
  | ':' '{' ListPortTypeConstraint '}' { PortTypePDT $3 }


PortDeclarationConnection :: { PortDeclarationConnection }
PortDeclarationConnection : {- empty -} { EmptyPDC } 
  | Connection ListExpression { Connection $1 $2 }


Expression :: { Expression }
Expression : Integer { IntExpression $1 } 
  | String { StringExpression $1 }
  | Direction { DirectionExpression $1 }
  | Position { PositionExpression $1 }
  | QualName { QualNameExpression $1 }
  | '(' Expression ')' { ParenExpression $2 }


Direction :: { Direction }
Direction : 'input' { InputDirection } 
  | 'output' { OutputDirection }
  | 'bidirectional' { BidirectionalDirection }


Position :: { Position }
Position : 'subject' { SubjectPosition } 
  | 'object' { ObjectPosition }


QualName :: { QualName }
QualName : Name { UnQual $1 } 
  | QualName '.' Name { Qual $1 $3 }


Name :: { Name }
Name : ClassId { TypeIdent $1 } 
  | Identifier { Ident $1 }

PortTypeConstraint :: { PortTypeConstraint }
PortTypeConstraint : FlowId '=' NoneExpression { PortTypeConstraint $1 $3 } 


NoneExpression :: { NoneExpression }
NoneExpression : '*' { NoneE } 
  | Expression { SomeE $1 }


Connection :: { Connection }
Connection : '<-->' { BidirectionalConnection } 
  | '-->' { LeftToRightConnection }
  | '<--' { RightToLeftConnection }
  | '--' { NeutralConnection }


Identifier :: { Identifier }
Identifier : LIdent { Identifier $1 } 


PortId :: { PortId }
PortId : LIdent { PortId $1 } 


FlowId :: { FlowId }
FlowId : LIdent { FlowId $1 } 


ClassId :: { ClassId }
ClassId : UIdent { ClassId $1 } 


ListIdentifier :: { [Identifier] }
ListIdentifier : {- empty -} { [] } 
  | Identifier { (:[]) $1 }
  | Identifier ',' ListIdentifier { (:) $1 $3 }


ListExpression :: { [Expression] }
ListExpression : {- empty -} { [] } 
  | Expression { (:[]) $1 }
  | Expression ',' ListExpression { (:) $1 $3 }


ListStatement :: { [Statement] }
ListStatement : {- empty -} { [] } 
  | ListStatement Statement { flip (:) $1 $2 }


ListPortTypeConstraint :: { [PortTypeConstraint] }
ListPortTypeConstraint : {- empty -} { [] } 
  | PortTypeConstraint { (:[]) $1 }
  | PortTypeConstraint ',' ListPortTypeConstraint { (:) $1 $3 }



{
annPos :: Posn -> Statement -> Statement
annPos pos stmt = Annotated ann stmt
  where
    ann = Annotation [(UIdent "SourcePos",
                       [StringExpression filename,
                        IntExpression (fromIntegral line),
                        IntExpression (fromIntegral column)])]
    filename = "unknown"
    Pn _ line column = pos

posError :: Posn -> Error -> Error
posError pos err = LocError loc err
  where
    loc = ErrorLoc "unknown" (fromIntegral line) (fromIntegral column)
    Pn _ line column = pos

happyError :: [Token] -> Err a
happyError ts =
  case ts of
    [] -> throwE $ SyntaxError "syntax error"
    [Err p] -> throwE $ posError p (SyntaxError "syntax error")
    -- TODO: could show token here
    PT p _ : _ -> throwE $ posError p (SyntaxError "syntax error")

myLexer = tokens
}

