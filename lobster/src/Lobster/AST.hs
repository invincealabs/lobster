module Lobster.AST where

import Data.Monoid

newtype LIdent = LIdent String deriving (Eq,Ord,Show)
newtype UIdent = UIdent String deriving (Eq,Ord,Show)

data Policy =
   Policy [Statement]
  deriving (Eq,Ord,Show)

type AnnotationElement = (UIdent, [Expression])

data Annotation = Annotation [AnnotationElement]
  deriving (Eq, Ord, Show)

instance Monoid Annotation where
  mempty = Annotation []
  mappend (Annotation a) (Annotation b) = Annotation (a ++ b)

-- TODO: re-evaulate using this type parameter for source location.
data Statement =
   ClassDeclaration ClassId [Identifier] [Statement]
 | PortDeclaration PortId PortDeclarationType PortDeclarationConnection
 | DomainDeclaration Identifier ClassInstantiation
 | Assignment Identifier Expression
 | PortConnection [Expression] Connection [Expression]
 | Assert ConnRE ConnRE FlowPred
 | Annotated Annotation Statement
  deriving (Eq,Ord,Show)

data ClassInstantiation =
   ClassInstantiation ClassId [Expression]
  deriving (Eq,Ord,Show)

data ConnRE =
   ConnRE DomainSpec PortRE
  deriving (Eq,Ord,Show)

data DomainSpec =
   ThisDom
 | IdentDom Identifier
  deriving (Eq,Ord,Show)

data PortRE =
   AnyPRE
 | IdPRE Identifier
  deriving (Eq,Ord,Show)

data FlowPred =
   NeverPathFP
 | ExistsPathFP
 | PathFP FlowRE
  deriving (Eq,Ord,Show)

data FlowRE =
   ConsF FlowRE ConnRE FlowRE
 | AnyFRE
  deriving (Eq,Ord,Show)

data PortDeclarationType =
   EmptyPDT
 | PortTypePDT [PortTypeConstraint]
  deriving (Eq,Ord,Show)

data PortDeclarationConnection =
   EmptyPDC
 | Connection Connection [Expression]
  deriving (Eq,Ord,Show)

data Expression =
   IntExpression Integer
 | StringExpression String
 | DirectionExpression Direction
 | PositionExpression Position
 | QualNameExpression QualName
 | ParenExpression Expression
  deriving (Eq,Ord,Show)

data Direction =
   InputDirection
 | OutputDirection
 | BidirectionalDirection
  deriving (Eq,Ord,Show)

data Position =
   SubjectPosition
 | ObjectPosition
  deriving (Eq,Ord,Show)

data QualName =
   UnQual Name
 | Qual QualName Name
  deriving (Eq,Ord,Show)

data Name =
   TypeIdent ClassId
 | Ident Identifier
  deriving (Eq,Ord,Show)

data PortTypeConstraint =
   PortTypeConstraint FlowId NoneExpression
  deriving (Eq,Ord,Show)

data NoneExpression =
   NoneE
 | SomeE Expression
  deriving (Eq,Ord,Show)

data Connection =
   BidirectionalConnection
 | LeftToRightConnection
 | RightToLeftConnection
 | NeutralConnection
  deriving (Eq,Ord,Show)

data Identifier =
   Identifier LIdent
  deriving (Eq,Ord,Show)

data PortId =
   PortId LIdent
  deriving (Eq,Ord,Show)

data FlowId =
   FlowId LIdent
  deriving (Eq,Ord,Show)

data ClassId =
   ClassId UIdent
  deriving (Eq,Ord,Show)
