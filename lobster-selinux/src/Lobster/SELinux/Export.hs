{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RankNTypes #-}
--
-- Export.hs --- Compiling Lobster to SELinux policy.
--
-- Copyright (C) 2014, Galois, Inc.
-- All Rights Reesrved.
--

module Lobster.SELinux.Export (
  exportSELinux
  ) where

import Control.Lens
import Data.List (find)
import Data.Maybe (isJust, catMaybes, fromMaybe)
import Data.Text (Text)

import Lobster.Core
import Text.PrettyPrint.Mainland

import qualified Data.Map          as M
import qualified Data.Set          as S
import qualified Data.Text         as T
import qualified Data.Text.Lazy    as TL
import qualified Data.Text.Lazy.IO as TLIO

----------------------------------------------------------------------
-- Utilities

expStringSEName :: Fold (Exp l) SEName
expStringSEName = _ExpString . to getLitString . to SEName

----------------------------------------------------------------------
-- Simple SELinux AST for Pretty Printing

-- | A symbolic identifier.
newtype SEName = SEName Text
  deriving (Eq, Ord, Show)

-- | Return a domain's name as an 'SEName'.
domSEName :: Domain l -> SEName
domSEName = SEName . view domainName

-- | Return a port's name as an 'SEName'.
portSEName :: Port l -> SEName
portSEName = SEName . view portName

-- | Information about an SELinux allow rule.
data Allow = Allow !SEName !SEName !SEName !(S.Set SEName)

-- | A statement in an SELinux policy.  We generate a limited set
-- of forms of the actual allowed syntax for simplicity.
data SEStmt
  = SEAttr     !SEName
  | SEType     !SEName
  | SETypeAttr !SEName !SEName
  | SEAllow    !Allow
  | SETrans    !SEName !SEName !SEName !SEName
  | SECall     !SEName [SEName]   -- m4 macro call

instance Pretty SEName where
  ppr (SEName x) = fromText x

instance Pretty SEStmt where
  ppr (SEAttr name) =
    text "attribute" <+> ppr name <> semi
  ppr (SEType name) =
    text "type" <+> ppr name <> semi
  ppr (SETypeAttr ty attr) =
    text "typeattribute" <+> ppr ty <+> ppr attr <> semi
  ppr (SEAllow (Allow subj obj cls perms)) =
    text "allow" <+> ppr subj <+> ppr obj <+> colon <+> ppr cls
                 <+> lbrace <+> (sep $ map ppr $ S.toList perms) <+> rbrace
                 <>  semi
  ppr (SETrans subj obj cls new) =
    text "type_transition" <+> ppr subj <+> ppr obj <+> colon <+> ppr cls
                           <+> ppr new <> semi
  ppr (SECall name args) =
    ppr name <> parens (commasep $ map ppr args)

----------------------------------------------------------------------
-- Cross-Module Port Lookups

-- | Look up a subdomain by name.
lookupSubdomain :: Module l -> Domain l -> Text -> Maybe (Domain l)
lookupSubdomain m dom name =
  find ((name ==) . view domainName) (map getDom subdoms)
  where
    getDom x = view (idDomain x) m
    subdoms = S.toList (dom ^. domainSubdomains)

-- | Look up a domain port by name.
lookupPort :: Module l -> Domain l -> Text -> Maybe (Port l)
lookupPort m dom name =
  find ((name ==) . view portName) (map getPort ports)
  where
    getPort x = view (idPort x) m
    ports = S.toList (dom ^. domainPorts)

-- | Follow annotations across a cross module port.
crossModulePort :: Module l
                -> Connection l
                -> Lens' (Connection l) PortId
                -> Text
                -> Maybe PortId
crossModulePort m conn l t =
  let pid  = view l conn
      port = m ^. idPort pid
      dom1 = m ^. idDomain (port ^. portDomain)
      name = port ^. portName in
  if portIsModule name
     then
       case lookupAnnotation t (conn ^. connectionAnnotation) of
              Just [ ExpVar (VarName _ dom2)
                   , ExpVar (VarName _ port2)] -> do
                dom3  <- lookupSubdomain m dom1 dom2
                port3 <- lookupPort      m dom3 port2
                return (port3 ^. portId)
              _ -> Nothing
     else Just pid  -- regular connection

-- | Return the left port of a connection, accounting for
-- cross module ports.
leftPort :: Module l -> Connection l -> PortId
leftPort m conn =
  fromMaybe (conn ^. connectionLeft) (crossModulePort m conn connectionLeft "Lhs")

-- | Return the right port of a connection, accounting for
-- cross module ports.
rightPort :: Module l -> Connection l -> PortId
rightPort m conn =
  fromMaybe (conn ^. connectionRight) (crossModulePort m conn connectionRight "Rhs")

----------------------------------------------------------------------
-- Object Utilities

-- | Return true if a domain has a specific annotation.
domainHasAnnotation :: Text -> Domain l -> Bool
domainHasAnnotation s dom =
  isJust $ lookupAnnotation s (dom ^. domainAnnotation)

-- | Return true if a domain is an SELinux type.
domainIsType :: Domain l -> Bool
domainIsType = domainHasAnnotation "Type"

-- | Return true if a domain is an SELinux attribute.
domainIsAttr :: Domain l -> Bool
domainIsAttr = domainHasAnnotation "Attribute"

-- | Return true if a domain is a type or attribute.
domainIsTypeOrAttr :: Domain l -> Bool
domainIsTypeOrAttr dom = domainIsType dom || domainIsAttr dom

-- | Return true if a domain is a macro instantiation.
domainIsMacro :: Domain l -> Maybe (SEName, [SEName])
domainIsMacro dom =
  case lookupAnnotation "Macro" (dom ^. domainAnnotation) of
    Just exprs -> do
      let name = dom ^. domainClassName . to T.toLower
      return (SEName name, exprs ^.. folded . expStringSEName)
    Nothing    -> Nothing

-- | Return true if a port name is an attribute membership port.
portIsMember :: Text -> Bool
portIsMember s
  | s == "member_subj" = True
  | s == "member_obj"  = True
  | otherwise          = False

-- | Return true if a port name is an attribute port.
portIsAttr :: Text -> Bool
portIsAttr s
  | s == "attribute_subj" = True
  | s == "attribute_obj"  = True
  | otherwise             = False

-- | Return true if a port name is a cross-module port.
portIsModule :: Text -> Bool
portIsModule s
  | s == "module_subj" = True
  | s == "module_obj"  = True
  | otherwise          = False

-- | Return the type and attribute domains for a connection if it
-- represents attribute membership.
connIsMembership :: Module l -> Connection l -> Maybe (Domain l, Domain l)
connIsMembership m conn =
  let portL = m ^. idPort (leftPort m conn)
      nameL = portL ^. portName                  
      domL  = m ^. idDomain (portL ^. portDomain)
      portR = m ^. idPort (rightPort m conn)
      nameR = portR ^. portName
      domR  = m ^. idDomain (portR ^. portDomain) in
  if | portIsMember nameL && portIsAttr nameR ->
       Just (domL, domR)
     | portIsMember nameR && portIsAttr nameL ->
       Just (domR, domL)
     | otherwise ->
       Nothing

-- | Return the set of permissions from a connection.
connPerms :: Connection l -> S.Set SEName
connPerms conn = S.fromList (anns ^.. folded . folded . expStringSEName)
  where
    anns = lookupAnnotations "Perm" (conn ^. connectionAnnotation)

-- | Return the subject, object, class, and permissions for a
-- connection if it represents an allow rule.
connIsAllow :: Module l -> Connection l -> Maybe Allow
connIsAllow m conn =
  let portL = m ^. idPort (leftPort m conn)
      domL  = m ^. idDomain (portL ^. portDomain)
      portR = m ^. idPort (rightPort m conn)
      domR  = m ^. idDomain (portR ^. portDomain)
      perms = connPerms conn in
    if | domainIsTypeOrAttr domL && domainIsTypeOrAttr domR && not (S.null perms) ->
         case (portL ^. portPosition, portR ^. portPosition) of
           (PosSubject, PosObject) ->
             Just (Allow (domSEName domL) (domSEName domR)
                         (portSEName portR) perms)
           (PosObject, PosSubject) ->
             Just (Allow (domSEName domR) (domSEName domL)
                         (portSEName portL) perms)
           _ -> Nothing
       | otherwise -> Nothing

----------------------------------------------------------------------
-- Module Queries

-- | Return all SELinux type domains in a module.
moduleTypes :: DomainTree l -> [Domain l]
moduleTypes dt = filter (domainIsType) (allDomains dt)

-- | Return all SELinux attributes in a module.
moduleAttrs :: DomainTree l -> [Domain l]
moduleAttrs dt = filter (domainIsAttr) (allDomains dt)

-- | Return all attribute memberships in a module.
--
-- XXX I'm not sure this does the right thing for subdomains.
moduleTypeAttrs :: Module l -> [(Domain l, Domain l)]
moduleTypeAttrs m =
  catMaybes $ map (connIsMembership m) (M.elems (m ^. moduleConnections))

-- | Return all allow rules in a module.
moduleAllows :: Module l -> [Allow]
moduleAllows m =
  catMaybes $ map (connIsAllow m) (M.elems (m ^. moduleConnections))

-- | Return all macro call statements in a module.
moduleMacros :: Module l -> [(SEName, [SEName])]
moduleMacros m =
  catMaybes $ map domainIsMacro (M.elems (m ^. moduleDomains))

----------------------------------------------------------------------
-- Statement Generation

-- | Return type declarations for a domain tree.
moduleTypeDecls :: DomainTree l -> [SEStmt]
moduleTypeDecls = map (SEType . domSEName) . moduleTypes

-- | Return attribute declarations for a domain tree.
moduleAttrDecls :: DomainTree l -> [SEStmt]
moduleAttrDecls = map (SEAttr . domSEName) . moduleAttrs

-- | Return attribute membership declarations.
moduleTypeAttrDecls :: Module l -> [SEStmt]
moduleTypeAttrDecls m =
  [ SETypeAttr (domSEName ty) (domSEName attr)
  | (ty, attr) <- moduleTypeAttrs m
  ]

-- | Return allow declarations for a module.
moduleAllowDecls :: Module l -> [SEStmt]
moduleAllowDecls = map SEAllow . moduleAllows

-- | Return macro calls for a module.
moduleCalls :: Module l -> [SEStmt]
moduleCalls m = [SECall f args | (f, args) <- moduleMacros m]

-- | Return a list of statements for a module.
--
-- TODO: Consider returning a data type here so we can pretty
-- print it more nicely.
moduleDecls :: Module l -> [SEStmt]
moduleDecls m = types ++ attrs ++ typeAttrs ++ allows ++ calls
  where
    dtree = domainTree m
    types = moduleTypeDecls dtree
    attrs = moduleAttrDecls dtree
    typeAttrs = moduleTypeAttrDecls m
    allows = moduleAllowDecls m
    calls = moduleCalls m

-- | Export a Lobster module to an SELinux policy file as lazy text.
exportSELinux :: Module l -> TL.Text
exportSELinux m = prettyLazyText 120 doc
  where
    doc = stack $ map ppr $ moduleDecls m