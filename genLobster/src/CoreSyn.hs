{-# OPTIONS_GHC -Wall #-}
module CoreSyn
  ( Decl
  , Name
  , QualifiedName
  , Qualifier
  , nameString
  , mkName
  , mkQualifiedName
  , rootModule
  , DomPort
  , ModPort
  , Dir
  , Param
  , ConnectAnnotation
  , mkAnnotation
  , AnnotationElement
  , annotationInt
  , annotationString
  , annotationName

  , lobsterModule
  , newClass
  , newExplicitClass
  , newDomain
  , newDomain'
  , anonDomain
  , anonExplicitDomain
  , anonExplicitDomain'
  , anonDomain'
  , newPort
  , newPortPos
  , newComment

  , domPort
  , modPort
  , extPort
  , portDomain
  , left
  , right
  , neutral
  , negative
  , bidi
  , connect
  , neutral'
  , connect'

  , showLobster
  , showLobsterBS
  ) where

import Data.Text.Lazy.Encoding (encodeUtf8)

import qualified Lobster.Core as L
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as Text
import qualified Text.PrettyPrint.Mainland as P

type Name = L.VarName L.Span
type Qualifier = L.Qualifier L.Span
type QualifiedName = L.Qualified L.VarName L.Span
type Param = Name
type Dir = L.ConnType
type DomPort = L.PortName L.Span
type ModPort = L.PortName L.Span
type AnnotationElement = L.Exp L.Span
type ConnectAnnotation = L.AnnotationElement L.Span
type Decl = L.Stmt L.Span

mkName :: String -> Name
mkName s = L.VarName L.emptySpan (Text.pack s)

mkQualifiedName :: [Qualifier] -> String -> QualifiedName
mkQualifiedName (q:qs) name = L.Qualified L.emptySpan q (mkQualifiedName qs name)
mkQualifiedName []     name = L.Unqualified (mkName name)

rootModule :: Qualifier
rootModule = L.RootModule L.emptySpan

moduleName :: Name -> Qualifier
moduleName name = L.ModuleName name

nameString :: Name -> String
nameString (L.VarName _ s) = Text.unpack s

lobsterModule :: Name -> [Decl] -> Decl
lobsterModule name decls = L.StmtModuleDecl L.emptySpan name decls

newClass :: Name -> [Param] -> [Decl] -> Decl
newClass (L.VarName s c) ps body =
  L.StmtClassDecl L.emptySpan False (L.TypeName s c) ps body

newExplicitClass :: Name -> [Param] -> [Decl] -> Decl
newExplicitClass (L.VarName s c) ps body =
  L.StmtClassDecl L.emptySpan True (L.TypeName s c) ps body

anonDomain :: Name -> [Decl] -> Decl
anonDomain binder decls =
  L.StmtAnonDomainDecl L.emptySpan False binder decls

anonDomain' :: Name -> [Decl] -> [ConnectAnnotation] -> Decl
anonDomain' binder decls xs =
  annotateDecl xs (anonDomain binder decls)

anonExplicitDomain :: Name -> [Decl] -> Decl
anonExplicitDomain binder decls =
  L.StmtAnonDomainDecl L.emptySpan True binder decls

anonExplicitDomain' :: Name -> [Decl] -> [ConnectAnnotation] -> Decl
anonExplicitDomain' binder decls xs =
  annotateDecl xs (anonExplicitDomain binder decls)


newPort :: Name -> Decl
newPort nm = L.StmtPortDecl L.emptySpan nm []

newPortPos :: Name -> L.Position -> Decl
newPortPos name pos = L.StmtPortDecl L.emptySpan name [attr]
  where
    attr = L.PortAttr (mkName "position")
                      (Just (L.ExpPosition (L.LitPosition L.emptySpan pos)))

newComment :: Text.Text -> Decl
newComment t = L.StmtComment L.emptySpan t

mkAnnotation :: Name -> [AnnotationElement] -> ConnectAnnotation
mkAnnotation (L.VarName s n) xs = (L.TypeName s n, xs)

annotationInt :: Int -> AnnotationElement
annotationInt = L.ExpInt . L.LitInteger L.emptySpan . toInteger

annotationString :: String -> AnnotationElement
annotationString = L.ExpString . L.LitString L.emptySpan . Text.pack

annotationName :: Name -> AnnotationElement
annotationName = L.ExpVar . L.Unqualified

annotateDecl :: [ConnectAnnotation] -> Decl -> Decl
annotateDecl xs = L.StmtAnnotation L.emptySpan (L.Annotation xs)

newDomain :: Name -> QualifiedName -> [Param] -> Decl
newDomain binder className args =
  L.StmtDomainDecl L.emptySpan binder (typeName className) args'
  where
    typeName (L.Unqualified (L.VarName s c)) = L.Unqualified (L.TypeName s c)
    typeName (L.Qualified l qualifier rest)    = L.Qualified l qualifier (typeName rest)
    args' = map (L.ExpVar . L.Unqualified) args

newDomain' :: Name -> QualifiedName -> [Param] -> [ConnectAnnotation] -> Decl
newDomain' binder ctor args xs = annotateDecl xs (newDomain binder ctor args)

domPort :: Name -> Name -> DomPort
domPort a b = L.Qualified L.emptySpan (L.DomainName a) (L.Unqualified b)

modPort :: Name -> Name -> Name -> ModPort
modPort m d p = L.Qualified L.emptySpan (L.ModuleName m) (domPort d p)

extPort :: Name -> DomPort
extPort b = L.Unqualified b

portDomain :: DomPort -> Maybe Name
portDomain (L.Unqualified _) = Nothing
portDomain (L.Qualified _ (L.DomainName d) _) = Just d
portDomain (L.Qualified _ _ rest) = portDomain rest

left :: DomPort -> DomPort -> Decl
left = connect L.ConnRightToLeft

right :: DomPort -> DomPort -> Decl
right = connect L.ConnLeftToRight

neutral :: DomPort -> DomPort -> Decl
neutral = connect L.ConnNeutral

neutral' :: DomPort -> DomPort -> [ConnectAnnotation] -> Decl
neutral' = connect' L.ConnNeutral

negative :: DomPort -> DomPort -> Decl
negative = connect L.ConnNegative

bidi :: DomPort -> DomPort -> Decl
bidi = connect L.ConnBidirectional

connect :: Dir -> DomPort -> DomPort -> Decl
connect d a b = L.StmtConnection L.emptySpan a (L.ConnOp L.emptySpan d) b

connect' :: Dir -> DomPort -> DomPort -> [ConnectAnnotation] -> Decl
connect' d a b xs = annotateDecl xs (connect d a b)

showLobster :: [Decl] -> String
showLobster ds = P.pretty 0 (P.ppr (L.Policy L.emptySpan ds))

showLobsterBS :: [Decl] -> LBS.ByteString
showLobsterBS ds = encodeUtf8 (P.prettyLazyText 0 (P.ppr (L.Policy L.emptySpan ds)))
