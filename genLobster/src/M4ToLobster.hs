{-# OPTIONS -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module M4ToLobster where

import Control.Error
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Char
import Data.Foldable (toList)
import Data.List (foldl')
import Data.Map (Map)
import Data.Set (Set)
import Data.Text (Text)

import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.MapSet as MapSet
import qualified Data.Text as T

import SCD.M4.PrettyPrint ()
import SCD.M4.Syntax hiding (avPerms)
import qualified SCD.M4.Syntax as M4

import qualified SCD.SELinux.Syntax as S
import qualified Text.Happy.ParserMonad as P

import qualified CoreSyn as L
import qualified Lobster.Core as C

import SCD.M4.Subst (Macros(..), expandPolicyModule)

import M4ToLobster.Error

ordNub :: Ord a => [a] -> [a]
ordNub = Set.toList . Set.fromList

----------------------------------------------------------------------
-- State monad

data AllowRule = AllowRule
  { allowSubject    :: S.TypeOrAttributeId
  , allowObject     :: S.TypeOrAttributeId
  , allowClass      :: S.ClassId
  , allowConditions :: [(Either M4.IfdefId S.CondExpr, Bool)]
  } deriving (Eq, Ord, Show)

data SysDomain l = SysDomain
  { sysDomainType    :: !(C.VarName l)
  , sysDomainVar     :: !(C.VarName l)
  , sysDomainArgs    :: [(Text, [C.Exp l])]
  } deriving Show

data St = St
  { object_classes   :: !(Map S.TypeOrAttributeId (Set S.ClassId))
  , class_perms      :: !(Map S.ClassId (Set S.PermissionId))
  , attrib_members   :: !(Map S.AttributeId (Set S.TypeId))
  -- attributes used as a subject in an allow rule
  , subj_attribs     :: !(Set S.AttributeId)
  -- attributes used as an object in an allow rule
  , obj_attribs      :: !(Set S.AttributeId)
  , allow_rules      :: !(Map AllowRule (Map S.PermissionId (Set P.Pos)))
  , type_transitions :: !(Set (S.TypeId, S.TypeId, S.ClassId, S.TypeId))
  , domtrans_macros  :: !(Set (S.Identifier, [S.TypeOrAttributeId]))
  , type_modules     :: !(Map S.Identifier M4.ModuleId)
  , type_aliases     :: !(Map S.Identifier S.Identifier)
  , roles            :: !(Map S.TypeOrAttributeId (Set S.RoleId))
  , unique_supply    :: Int
  , sys_domains      :: ![SysDomain C.Span]
  }

processClassId :: S.ClassId
processClassId = S.mkId "process"

activePermissionId :: S.PermissionId
activePermissionId = S.mkId "active"

initSt :: St
initSt = St
  { object_classes   = Map.empty
  , class_perms      = Map.singleton processClassId (Set.singleton activePermissionId)
  , attrib_members   = Map.empty
  , subj_attribs     = Set.empty
  , obj_attribs      = Set.empty
  , allow_rules      = Map.empty
  , type_transitions = Set.empty
  , domtrans_macros  = Set.empty
  , type_modules     = Map.empty
  , type_aliases     = Map.empty
  , roles            = Map.empty
  , unique_supply    = 0
  , sys_domains      = []
  }

data Env = Env
  { envPositions :: [P.Pos]
  , envConditions :: [(Either M4.IfdefId S.CondExpr, Bool)]
  , envModuleId :: M4.ModuleId
  }

initEnv :: Env
initEnv = Env
  { envPositions = []
  , envConditions = []
  , envModuleId = S.mkId "none"
  }

setModuleId :: M4.ModuleId -> Env -> Env
setModuleId i e = e { envModuleId = i }

addPos :: P.Pos -> Env -> Env
addPos p e = e { envPositions = p : envPositions e }

addIfdef :: Bool -> M4.IfdefId -> Env -> Env
addIfdef b i e = e { envConditions = (Left i, b) : envConditions e }

addCond :: Bool -> S.CondExpr -> Env -> Env
addCond b c e = e { envConditions = (Right c, b) : envConditions e }

type M a = ReaderT Env (State St) a

getUnique :: M Int
getUnique = do
  st <- get
  let n = unique_supply st
  put $ st { unique_supply = n + 1 }
  return n

addSysDomain :: Text -> [(Text, [C.Exp C.Span])] -> M ()
addSysDomain ty args = do
  n <- getUnique
  let varName = C.VarName C.emptySpan (T.pack $ "dom" ++ show n)
  let sysDom = SysDomain (C.VarName C.emptySpan ty) varName args
  modify $ \st -> st { sys_domains = sysDom : (sys_domains st) }

----------------------------------------------------------------------
-- Processing of M4 policy

filterSignedId :: Eq a => [S.SignedId a] -> [a]
filterSignedId xs = [ y | y <- ys, y `notElem` zs ]
  where
    (ys, zs) = partitionEithers (map f xs)
    f (S.SignedId S.Positive y) = Left y
    f (S.SignedId S.Negative z) = Right z

identifierToExp :: S.IsIdentifier a => a -> C.Exp C.Span
identifierToExp x =
  let s = T.pack $ S.idString $ S.toId x in
    -- Note: If the SELinux identifier would be confused for a Lobster
    -- type due to an initial upper-case letter, we turn it into a string
    -- literal, which is also supported by the exporter.
    if isUpper (T.head s)
      then C.ExpString (C.LitString C.emptySpan s)
      else C.ExpVar (C.Unqualified (C.VarName C.emptySpan s))

signedIdToExp :: S.IsIdentifier a => S.SignedId a -> C.Exp C.Span
signedIdToExp signedId =
  case signedId of
    S.SignedId S.Negative x -> C.ExpUnaryOp C.emptySpan C.UnaryOpNot (identifierToExp x)
    S.SignedId S.Positive x -> identifierToExp x

fromSelf :: S.TypeOrAttributeId -> S.Self -> S.TypeOrAttributeId
fromSelf x S.Self = x
fromSelf _ (S.NotSelf x) = x

insertMapSet :: (Ord k, Ord a) => k -> a -> Map k (Set a) -> Map k (Set a)
insertMapSet k x = Map.insertWith (flip Set.union) k (Set.singleton x)

addkeyMapSet :: (Ord k, Ord a) => k -> Map k (Set a) -> Map k (Set a)
addkeyMapSet = Map.alter (maybe (Just Set.empty) Just)

-- | Most class/permission pairs (c,p) indicate an information flow
-- between a *process* and an object of class c. However, some may
-- implicitly involve a different class: e.g. filesystem:associate
-- relates a *file* to a filesystem.
activeClass :: S.ClassId -> S.PermissionId -> S.ClassId
activeClass c p
  | c == S.mkId "filesystem" && p == S.mkId "associate" = S.mkId "file"
  | otherwise = processClassId

evalType :: S.IsIdentifier a => a -> M a
evalType t = do
  tas <- gets type_aliases
  return $! maybe t S.fromId (Map.lookup (S.toId t) tas)

addAllow :: S.TypeOrAttributeId -> S.TypeOrAttributeId
         -> S.ClassId -> Set S.PermissionId -> M ()
addAllow s o cls perms = do
  subject <- evalType s
  object  <- evalType o
  -- discard all but the outermost enclosing source position
  -- so that we only get the position of the top-level macro
  ps <- asks (Set.fromList . take 1 . reverse . envPositions)
  conds <- asks envConditions
  let rule = AllowRule subject object cls conds
  let posMap = Map.fromSet (const ps) perms
  let activeClasses = Set.map (activeClass cls) perms
  modify $ \st -> st
    { object_classes =
        Map.insertWith Set.union subject activeClasses $
        insertMapSet object cls $
        object_classes st
    , class_perms =
        flip (foldr (flip insertMapSet activePermissionId)) (Set.toList activeClasses) $
        Map.insertWith (flip Set.union) cls perms (class_perms st)
    , allow_rules = Map.insertWith (Map.unionWith Set.union) rule posMap (allow_rules st)
    }

  st <- get
  let subj = S.fromId (S.toId subject)
  let obj  = S.fromId (S.toId object)

  -- if the subject is an attribute, add it to the subject attribute set
  case Map.lookup subj (attrib_members st) of
    Just _  -> modify $ \x -> x { subj_attribs = Set.insert subj (subj_attribs st) }
    Nothing -> return ()

  -- if the object is an attribute, add it to the object attribute set
  case Map.lookup obj (attrib_members st) of
    Just _  -> modify $ \x -> x { obj_attribs = Set.insert obj (obj_attribs st) }
    Nothing -> return ()

addDeclaration :: S.IsIdentifier i => i -> M ()
addDeclaration i = do
  m  <- asks envModuleId
  modify $ \st ->
    st { type_modules = Map.insert (S.toId i) m (type_modules st) }

addAttrib :: S.AttributeId -> M ()
addAttrib attr =
  modify $ \st -> st
    { attrib_members = addkeyMapSet attr (attrib_members st)
    }

-- TODO: This currently ignores the `Sign` on types and attributes in role statements.
addRoles :: S.RoleId -> [S.SignedId S.TypeOrAttributeId] -> M ()
addRoles roleId domains =
  modify $ \st -> st
  { roles = foldl' (\m (S.SignedId _ t) -> insertMapSet t roleId m) (roles st) domains
  }

addTypeAttrib :: S.TypeId -> S.AttributeId -> M ()
addTypeAttrib ty attr = do
  ty' <- evalType ty
  modify (f ty')
  where
    f ty' st = st
      { object_classes = addkeyMapSet (S.fromId (S.toId attr)) (object_classes st)
      , attrib_members = insertMapSet attr ty' (attrib_members st)
      }

addTypeAttribs :: S.TypeId -> [S.AttributeId] -> M ()
addTypeAttribs ty attrs = mapM_ (addTypeAttrib ty) attrs

addTypeTransition :: S.TypeId -> S.TypeId -> S.ClassId -> S.TypeId -> M ()
addTypeTransition subj rel cls new = do
  subj' <- evalType subj
  rel'  <- evalType rel
  new'  <- evalType new
  modify (f subj' rel' new')
  where
    f subj' rel' new' st = st
      { object_classes =
          insertMapSet (S.fromId (S.toId subj')) processClassId $
          insertMapSet (S.fromId (S.toId new')) cls $
          object_classes st
      , type_transitions = Set.insert (subj', rel', cls, new') (type_transitions st)
      }

addDomtransMacro :: [S.TypeOrAttributeId] -> M ()
addDomtransMacro args = do
  args' <- mapM evalType args
  n <- getUnique
  let i = S.mkId ("domtrans" ++ show n)
  addDeclaration i
  modify $ \ st -> st
      { object_classes =
          foldr ($) (object_classes st)
            [ Map.insertWith Set.union d cs | (d, cs) <- zip args' argClasses ]
      , class_perms =
          insertMapSet (S.mkId "file") (S.mkId "x_file_perms") $
          class_perms st
      , domtrans_macros = Set.insert (i, args') (domtrans_macros st)
      }
  where
    argClasses :: [Set S.ClassId]
    argClasses =
      [ Set.fromList [processClassId, S.mkId "fd", S.mkId "fifo_file"]
      , Set.fromList [S.mkId "file"]
      , Set.fromList [processClassId]
      ]

addTypeAlias :: S.TypeId -> [S.TypeId] -> M ()
addTypeAlias t xs = do
  forM_ xs $ \alias -> do
    modify $ \st -> st
      { type_aliases = Map.insert (S.toId alias) (S.toId t) (type_aliases st) }

processStmts :: M4.Stmts -> M ()
processStmts = mapM_ processStmt

processAlias :: M4.Stmt -> M ()
processAlias stmt =
  case stmt of
    Type t aliases _    -> addTypeAlias t (toList aliases)
    TypeAlias t aliases -> addTypeAlias t (toList aliases)
    Tunable _ s1 s2     -> processAliases s1 >> processAliases s2
    Optional s1 s2      -> processAliases s1 >> processAliases s2
    Ifdef _ s1 s2       -> processAliases s1 >> processAliases s2
    Ifndef _ s          -> processAliases s
    CondStmt _ s1 s2    -> processAliases s1 >> processAliases s2
    StmtPosition s1 _   -> processAlias s1
    Require _           -> return ()
    _                   -> return ()

processAliases :: M4.Stmts -> M ()
processAliases = mapM_ processAlias

processStmt :: M4.Stmt -> M ()
processStmt stmt =
  case stmt of
    Tunable c stmts1 stmts2 -> do
      local (addCond True c) $ processStmts stmts1
      local (addCond False c) $ processStmts stmts2
    Optional stmts1 stmts2 -> do
      processStmts stmts1
      processStmts stmts2
    Ifdef i stmts1 stmts2 -> do
      local (addIfdef True i) $ processStmts stmts1
      local (addIfdef False i) $ processStmts stmts2
    Ifndef i stmts -> local (addIfdef False i) $ processStmts stmts
    RefPolicyWarn {} -> return ()
    Call m4id [al, bl, cl] | m4id == S.mkId "domtrans_pattern" ->
      sequence_ $
        [ addDomtransMacro [a, b, c]
        | a <- map (S.fromId . S.toId) $ filterSignedId $ toList al
        , b <- map (S.fromId . S.toId) $ filterSignedId $ toList bl
        , c <- map (S.fromId . S.toId) $ filterSignedId $ toList cl
        ]
    Call _ _ -> return () -- FIXME
    Role roleId ts    -> do
      addRoles roleId ts
      addSysDomain "role"
        [ ("Name", [identifierToExp roleId])
        , ("Types", map signedIdToExp ts)
        ]
    AttributeRole x ->
      addSysDomain "attribute_role"
        [ ("Name", [identifierToExp x])
        ]
    RoleAttribute roleId attrs ->
      addSysDomain "role_attribute"
        [ ("Role", [identifierToExp roleId])
        , ("Attributes", map identifierToExp (toList attrs))
        ]
    RoleTransition currentRoles typeIds newRole ->
      addSysDomain "role_transition"
        [ ("CurrentRoles", map identifierToExp (toList currentRoles))
        , ("Types", map signedIdToExp (toList typeIds))
        , ("NewRole", [identifierToExp newRole])
        ]
    RoleAllow fromRoles toRoles ->
      addSysDomain "role_allow"
        [ ("FromRole", map identifierToExp (toList fromRoles))
        , ("ToRole", map identifierToExp (toList toRoles))
        ]
    Attribute attr -> addDeclaration attr >> addAttrib attr
    Type t aliases attrs  -> do
      addDeclaration t
      addTypeAttribs t attrs
    TypeAlias t aliases ->
      addSysDomain "type_alias"
        [ ("Name", [identifierToExp t])
        , ("Aliases", map identifierToExp (toList aliases))
        ]
    TypeAttribute t attrs -> addTypeAttribs t (toList attrs)
    RangeTransition {} -> return ()
    TeNeverAllow {}    -> return () -- neverallow
    Transition trans (S.SourceTarget al bl cl) t ->
      case trans of
        S.TypeTransition ->
          sequence_ $
            [ addTypeTransition subject related classId object
            | let object = (S.fromId . S.toId) t
            , subject <- map (S.fromId . S.toId) $ filterSignedId $ toList al
            , related <- map (S.fromId . S.toId) $ filterSignedId $ toList bl
            , classId <- toList cl
            ]
        S.TypeMember -> return () -- type_member
        S.TypeChange -> return ()
    TeAvTab ad (S.SourceTarget al bl cl) ps ->
      case isAllow ad of
        True -> case ps of
          S.Permissions dl ->
            sequence_ $
              [ case object' of
                  S.Self      -> return ()
                  S.NotSelf _ -> addAllow subject object classId perms
              | subject <- filterSignedId $ toList al
              , object' <- filterSignedId $ toList bl
              , let object = fromSelf subject object'
              , classId <- toList cl
              , let perms = Set.fromList $ toList dl
              ]
          S.PStarTilde st -> case st of
            S.Tilde _ -> return () -- FIXME
            S.Star    -> return () -- FIXME
        False -> return () -- dontaudit / auditdeny
    CondStmt c stmts1 stmts2 -> do
      local (addCond True c) $ processStmts stmts1
      local (addCond False c) $ processStmts stmts2
    XMLDocStmt {}        -> return ()
    SidStmt {}           -> return ()
    FileSystemUseStmt {} -> return ()
    GenFileSystemStmt {} -> return ()
    PortStmt {}          -> return ()
    NetInterfaceStmt {}  -> return ()
    NodeStmt {}          -> return ()
    Define {}            -> return ()
    Require {}           -> return () -- gen_require
    GenBoolean {}        -> return () -- gen_bool / gen_tunable
    StmtPosition stmt1 pos -> local (addPos pos) $ processStmt stmt1

isAllow :: S.AllowDeny -> Bool
isAllow ad = case ad of
  S.Allow      -> True
  S.AuditAllow -> True
  S.AuditDeny  -> False
  S.DontAudit  -> False

processAliasesImplementation :: M4.Implementation -> M ()
processAliasesImplementation (M4.Implementation modId _ stmts) =
  local (setModuleId modId) $ processAliases stmts

processImplementation :: M4.Implementation -> M ()
processImplementation (M4.Implementation modId _ stmts) =
  local (setModuleId modId) $ mapM_ processStmt stmts

processAliasesModule :: M4.PolicyModule -> M ()
processAliasesModule m = processAliasesImplementation (M4.implementation m)

processPolicyModule :: M4.PolicyModule -> M ()
processPolicyModule m = processImplementation (M4.implementation m)

processPolicy :: [M4.PolicyModule] -> M ()
processPolicy modules = do
  mapM_ processAliasesModule modules
  mapM_ processPolicyModule  modules

----------------------------------------------------------------------
-- Sub-attributes

type SubAttribute = (S.AttributeId, S.AttributeId)

parseSubAttributes :: String -> [SubAttribute]
parseSubAttributes = parse . lines
  where
    parse [] = []
    parse (l : ls) =
      case words l of
        [sub, "<", sup] -> (S.mkId sub, S.mkId sup) : parse ls
        _ -> parse ls

-- | Requirement: isTopSorted subattributes
isTopSorted :: Eq a => [(a, a)] -> Bool
isTopSorted [] = True
isTopSorted (x : xs) = isTopSorted xs && snd x `notElem` map fst xs

-- | (a, b) must not precede (b, c); otherwise (b, c) will be removed.
ensureTopSorted :: Eq a => [(a, a)] -> [(a, a)]
ensureTopSorted [] = []
ensureTopSorted (x : ys) = x : ensureTopSorted [ y | y <- ys, fst y /= snd x ]

-- | For each type t in attribute a, and class c used with a, note
-- that c is also used with t.
processAttributes :: M ()
processAttributes = do
  st <- get
  let new = Map.fromListWith Set.union
        [ (S.fromId (S.toId t), cs)
        | (attr, ts) <- Map.assocs (attrib_members st)
        , let cs = MapSet.lookup (S.fromId (S.toId attr)) (object_classes st)
        , t <- Set.toList ts ]
  put $ st { object_classes = Map.unionWith Set.union new (object_classes st) }

-- | Checking of sub-attribute membership: Ensure that all types t in
-- attribute x are also in attribute y.
checkSubAttribute :: SubAttribute -> M Bool
checkSubAttribute (x, y) = do
  m <- gets attrib_members
  return (Set.isSubsetOf (MapSet.lookup x m) (MapSet.lookup y m))
  -- TODO: use error monad with a decent error message instead of returning Bool.

-- | For each pair (x, y) (indicating that x is a sub-attribute of y)
-- we 1) for any class c used with y, note that c is also used with x;
-- 2) drop the explicit membership of t in y for any type t in x.
processSubAttribute :: SubAttribute -> M ()
processSubAttribute (x, y) = do
  st <- get
  let oc = object_classes st
  let oc' = Map.insertWith Set.union (S.fromId (S.toId x)) (MapSet.lookup (S.fromId (S.toId y)) oc) oc
  let am = attrib_members st
  let am' = Map.insertWith (flip Set.difference) y (MapSet.lookup x am) am
  put $ st { object_classes = oc', attrib_members = am' }

isDeclared :: S.IsIdentifier i => i -> M Bool
isDeclared i = do
  st <- get
  return (Map.member (S.toId i) (type_modules st))

processSubAttributes :: [SubAttribute] -> M [SubAttribute]
processSubAttributes subs0 = do
  let subs1 = ensureTopSorted subs0 -- ^ (b < c) must come *before* (a < b)
  subs2 <- filterM (isDeclared . fst) subs1
  subs3 <- filterM (isDeclared . snd) subs2
  subs4 <- filterM checkSubAttribute subs3
  mapM_ processSubAttribute subs4
  return subs4

----------------------------------------------------------------------
-- Generation of Lobster code

type Dom = L.Name
type Mod = L.Name
type Port = L.Name

activePort :: Port
activePort = L.mkName "active"

subjMemberPort :: Port
subjMemberPort = L.mkName "member_subj"

objMemberPort :: Port
objMemberPort = L.mkName "member_obj"

subjAttrPort :: Port
subjAttrPort = L.mkName "attribute_subj"

objAttrPort :: Port
objAttrPort = L.mkName "attribute_obj"

toDom :: S.IsIdentifier i => i -> Dom
toDom = L.mkName . lowercase . S.idString

toMod :: S.IsIdentifier i => i -> Mod
toMod = L.mkName . lowercase . S.idString

toPort :: S.IsIdentifier i => i -> Port
toPort = L.mkName . lowercase . S.idString

toIdentifier :: S.IsIdentifier i => i -> S.ClassId -> Dom
toIdentifier typeId classId = L.mkName (lowercase (S.idString typeId ++ "__" ++ S.idString classId))

outputModule :: M4.ModuleId -> L.ConnectAnnotation
outputModule i =
  L.mkAnnotation (L.mkName "Module")
    [L.annotationString (S.idString i)]

outputPerm :: S.ClassId -> S.PermissionId -> L.ConnectAnnotation
outputPerm cls p =
  L.mkAnnotation (L.mkName "Perm")
    [ L.annotationString (S.idString cls)
    , L.annotationString (S.idString p)]

outputPos :: P.Pos -> L.ConnectAnnotation
outputPos (P.Pos fname _ l c) =
  L.mkAnnotation (L.mkName "SourcePos")
    [L.annotationString fname, L.annotationInt l, L.annotationInt c]

outputCond :: (Either M4.IfdefId S.CondExpr, Bool) -> L.ConnectAnnotation
outputCond (Left i, b) =
  L.mkAnnotation (L.mkName (if b then "Ifdef" else "Ifndef"))
    [L.annotationString (S.idString i)]
outputCond (Right c, b) =
  L.mkAnnotation (L.mkName "CondExpr")
    [outputCondExpr (if b then c else S.Not c)]

outputCondExpr :: S.CondExpr -> C.Exp C.Span
outputCondExpr c =
  case c of
    S.Not c1      -> C.ExpUnaryOp C.emptySpan C.UnaryOpNot (outputCondExpr c1)
    S.Op c1 op c2 -> C.ExpBinaryOp C.emptySpan (outputCondExpr c1) (outputOp op) (outputCondExpr c2)
    S.Var i       -> C.ExpVar (C.Unqualified (L.mkName (S.idString i)))
  where
    outputOp :: S.Op -> C.BinaryOp
    outputOp S.And = C.BinaryOpAnd
    outputOp S.Or  = C.BinaryOpOr
    outputOp S.Xor = error "xor unimplemented"
    outputOp S.Equals = C.BinaryOpEqual
    outputOp S.Notequal = C.BinaryOpNotEqual

moduleEdges ::
  St -> (S.Identifier, Port) -> (S.Identifier, Port) -> [L.ConnectAnnotation] -> [(Maybe M4.ModuleId, L.Decl)]
moduleEdges st (d1, p1) (d2, p2) anns
  | m1 == m2 = [(m1, L.neutral' (L.domPort (toDom d1) p1) (L.domPort (toDom d2) p2) anns)]
  | otherwise = [(Nothing, L.neutral' qualPort1 qualPort2 anns)]
  where
    m1 = Map.lookup d1 (type_modules st)
    m2 = Map.lookup d2 (type_modules st)
    qualPort1 = toQualPort m1 d1 p1
    qualPort2 = toQualPort m2 d2 p2

    toQualPort m d p = case m of
      Just modId -> L.modPort (toMod modId) (toDom d) p
      Nothing    -> L.domPort (toDom d) p

outputAllowRule :: St -> (AllowRule, Map S.PermissionId (Set P.Pos)) -> [(Maybe M4.ModuleId, L.Decl)]
outputAllowRule st (AllowRule subject object cls conds, m) =
  moduleEdges st
    (S.toId subject, activePort)
    (S.toId object, toPort cls)
    (map (outputPerm cls) perms ++ map outputCond conds ++ map outputPos ps)
  where
    perms = Map.keys m
    ps = Set.toList (Set.unions (Map.elems m))

outputSubjAttr :: St -> S.TypeId -> S.AttributeId -> [(Maybe M4.ModuleId, L.Decl)]
outputSubjAttr st ty attr =
  moduleEdges st
    (S.toId ty, subjMemberPort)
    (S.toId attr, subjAttrPort)
    [L.mkAnnotation (L.mkName "Attribute") []]

outputObjAttr :: St -> S.TypeId -> S.AttributeId -> [(Maybe M4.ModuleId, L.Decl)]
outputObjAttr st ty attr =
  moduleEdges st
    (S.toId attr, objAttrPort)
    (S.toId ty, objMemberPort)
    [L.mkAnnotation (L.mkName "Attribute") []]

outputSubAttribute :: St -> S.AttributeId -> S.AttributeId -> [(Maybe M4.ModuleId, L.Decl)]
outputSubAttribute st ty attr =
  moduleEdges st
    (S.toId ty, subjMemberPort)
    (S.toId attr, subjAttrPort)
    [L.mkAnnotation (L.mkName "SubAttribute") []] ++
  moduleEdges st
    (S.toId attr, objAttrPort)
    (S.toId ty, objMemberPort)
    [L.mkAnnotation (L.mkName "SubAttribute") []]

outputTypeTransition :: St -> (S.TypeId, S.TypeId, S.ClassId, S.TypeId) -> [(Maybe M4.ModuleId, L.Decl)]
outputTypeTransition st (subj, rel, cls, new) =
  moduleEdges st
    (S.toId subj, activePort)
    (S.toId new, toPort cls)
    [L.mkAnnotation (L.mkName "TypeTransition") [L.annotationString (S.idString rel)]]

domtransDecl :: L.Decl
domtransDecl =
  L.newExplicitClass (L.mkName "Domtrans_pattern") [d2_name]
    [ L.newPortPos d1_active C.PosObject
    , L.newPortPos d1_fd     C.PosSubject
    , L.newPortPos d1_fifo   C.PosSubject
    , L.newPortPos d1_proc   C.PosSubject
    , L.newPortPos d2_file   C.PosSubject
    , L.newPortPos d3_active C.PosObject
    , L.newPortPos d3_proc   C.PosSubject
    , L.neutral' (L.extPort d1_active) (L.extPort d2_file)
        (map (perm (S.mkId "file")) ["getattr", "open", "read", "execute"])
    , L.neutral' (L.extPort d1_active) (L.extPort d3_proc)
        [outputPerm (S.mkId "process") (S.mkId "transition"),
         L.mkAnnotation (L.mkName "TypeTransition") [L.annotationName d2_name]]
    , L.neutral' (L.extPort d3_active) (L.extPort d1_fd)
        [outputPerm (S.mkId "fd") (S.mkId "use")]
    , L.neutral' (L.extPort d3_active) (L.extPort d1_fifo)
        (map (perm (S.mkId "fifo_file")) ["getattr", "open", "read", "write", "append", "ioctl", "lock"])
    , L.neutral' (L.extPort d3_active) (L.extPort d1_proc)
        [outputPerm (S.mkId "process") (S.mkId "sigchld")]
    ]
  where
    d1_active = L.mkName "d1_active"
    d1_fd     = L.mkName "d1_fd"
    d1_fifo   = L.mkName "d1_fifo_file"
    d1_proc   = L.mkName "d1_process"
    d2_file   = L.mkName "d2_file"
    d3_active = L.mkName "d3_active"
    d3_proc   = L.mkName "d3_process"
    d2_name   = L.mkName "d2_name"
    perm cls  = outputPerm cls . S.mkId

outputDomtransMacro :: St -> (S.Identifier, [S.TypeOrAttributeId]) -> [(Maybe M4.ModuleId, L.Decl)]
outputDomtransMacro st (n, ds) = (m, domDecl) : concatMap connectArg args
  where
    d :: Dom
    d = L.mkName (S.idString n)

    m :: Maybe M4.ModuleId
    m = Map.lookup n (type_modules st)

    domDecl :: L.Decl
    domDecl = L.newDomain' d (L.mkQualifiedName [L.rootModule] "Domtrans_pattern") [L.mkName (show (S.idString (ds !! 1)))]
      [L.mkAnnotation (L.mkName "Macro") (map (L.annotationString . S.idString) ds)]

    connectArg :: (S.Identifier, L.Name, S.Identifier, L.Name) -> [(Maybe M4.ModuleId, L.Decl)]
    connectArg (subjDom, subjPort, objDom, objPort) =
      moduleEdges st
        (subjDom, subjPort)
        (objDom,  objPort)
        [L.mkAnnotation (L.mkName "MacroArg") []]

    args :: [(S.Identifier, L.Name, S.Identifier, L.Name)]
    args =
      [ (argDom 0, activePort,              macroDom, L.mkName "d1_active")
      , (macroDom, L.mkName "d1_fd",        argDom 0, L.mkName "fd")
      , (macroDom, L.mkName "d1_fifo_file", argDom 0, L.mkName "fifo_file")
      , (macroDom, L.mkName "d1_process",   argDom 0, L.mkName "process")
      , (macroDom, L.mkName "d2_file",      argDom 1, L.mkName "file")
      , (argDom 2, activePort,              macroDom, L.mkName "d3_active")
      , (macroDom, L.mkName "d3_process",   argDom 2, L.mkName "process")
      ]
      where
        argDom n = S.toId (ds !! n)
        macroDom = S.mkId (L.nameString d)

rolesAnn :: S.TypeOrAttributeId -> St -> Maybe L.ConnectAnnotation
rolesAnn ty st = do
  roleIds <- Map.lookup ty (roles st)
  let roleNames = fmap (L.annotationName . L.mkName . S.idString) (Set.toList roleIds)
  return $ L.mkAnnotation (L.mkName "Roles") roleNames

sysDomainToLobster :: SysDomain C.Span -> L.Decl
sysDomainToLobster sysDom =
  L.anonDomain' (sysDomainVar sysDom) []
    ([ L.mkAnnotation (L.mkName "SysDomain") [L.annotationName $ sysDomainType sysDom]
     ] ++ map go (sysDomainArgs sysDom))
  where
    go (name, exprs) =
      L.mkAnnotation (C.VarName C.emptySpan name) exprs

outputLobster :: M4.Policy -> (St, [SubAttribute]) -> [L.Decl]
outputLobster _ (st, subattrs) =
  domtransDecl :
  [ L.lobsterModule (toMod m) (reverse ds)
    | (Just m, ds) <- Map.assocs groupedDecls ] ++
  Map.findWithDefault [] Nothing groupedDecls ++
  [selinuxModule]
  where
    isAttr ty =
      Map.member (S.fromId (S.toId ty)) (attrib_members st)

    typeDecl (ty, classes) = (modId, decl)
      where
        modId  = Map.lookup (S.toId ty) (type_modules st)
        decl   = L.anonDomain' (toDom ty) (header ++ stmts) anns
        header = [ L.newPortPos activePort     C.PosSubject
                 , L.newPortPos subjMemberPort C.PosSubject
                 , L.newPortPos objMemberPort  C.PosObject
                 ]
        stmts  = [ L.newPortPos (toPort c) C.PosObject
                 | c <- Set.toList classes
                 ]
        anns   = L.mkAnnotation (L.mkName "Type") [] : maybeToList (rolesAnn ty st)

    attrDecl (ty, classes) = (modId, decl)
      where
        modId  = Map.lookup (S.toId ty) (type_modules st)
        decl   = L.anonExplicitDomain' (toDom ty) (header ++ stmts) [ann]
        header = [ L.newPortPos activePort     C.PosSubject
                 , L.newPortPos subjMemberPort C.PosSubject
                 , L.newPortPos objMemberPort  C.PosObject
                 , L.newPortPos subjAttrPort   C.PosObject
                 , L.newPortPos objAttrPort    C.PosSubject
                 ]
        stmts  = [ L.newPortPos (toPort c) C.PosObject
                 | c <- Set.toList classes ] ++
                 [ L.neutral (L.extPort subjAttrPort) (L.extPort activePort)
                 , L.neutral (L.extPort subjAttrPort) (L.extPort subjMemberPort)
                 , L.neutral (L.extPort objAttrPort)  (L.extPort objMemberPort)
                 ] ++
                 [ L.neutral (L.extPort objAttrPort)  (L.extPort (toPort c))
                 | c <- Set.toList classes
                 ]
        ann    = L.mkAnnotation (L.mkName "Attribute") []

    domainDecl :: (S.TypeOrAttributeId, Set S.ClassId) -> (Maybe M4.ModuleId, L.Decl)
    domainDecl (ty, classes) =
      if isAttr ty
        then attrDecl (ty, classes)
        else typeDecl (ty, classes)

    domainDecls :: [(Maybe M4.ModuleId, L.Decl)]
    domainDecls = map domainDecl (Map.assocs (object_classes st))

    connectionDecls :: [(Maybe M4.ModuleId, L.Decl)]
    connectionDecls = concatMap (outputAllowRule st) (Map.assocs (allow_rules st))

    subjAttrDecls attr ty =
      if Set.member attr (subj_attribs st)
        then outputSubjAttr st ty attr
        else []

    objAttrDecls attr ty =
      if Set.member attr (obj_attribs st)
        then outputObjAttr st ty attr
        else []

    attributeDecls :: [(Maybe M4.ModuleId, L.Decl)]
    attributeDecls = do
      (attr, tys) <- Map.assocs (attrib_members st)
      ty <- Set.toList tys
      subjAttrDecls attr ty ++ objAttrDecls attr ty

    subAttributeDecls :: [(Maybe M4.ModuleId, L.Decl)]
    subAttributeDecls = do
      (sub, sup) <- subattrs
      outputSubAttribute st sub sup

    transitionDecls :: [(Maybe M4.ModuleId, L.Decl)]
    transitionDecls = do
      tt <- Set.toList (type_transitions st)
      outputTypeTransition st tt

    domtransDecls :: [(Maybe M4.ModuleId, L.Decl)]
    domtransDecls = concatMap (outputDomtransMacro st) (Set.toList (domtrans_macros st))

    taggedDecls :: [(Maybe M4.ModuleId, L.Decl)]
    taggedDecls =
      domainDecls ++ ordNub connectionDecls ++ attributeDecls ++ subAttributeDecls
        ++ transitionDecls ++ domtransDecls

    groupedDecls :: Map (Maybe M4.ModuleId) [L.Decl] -- in reverse order
    groupedDecls = Map.fromListWith (++) [ (m, [d]) | (m, d) <- taggedDecls ]

    selinuxModule :: L.Decl
    selinuxModule =
      L.lobsterModule (L.mkName "selinux__") $ reverse $ map sysDomainToLobster (sys_domains st)

----------------------------------------------------------------------

-- | Convert a policy to Lobster.
toLobster :: [SubAttribute] -> Policy -> Either Error [L.Decl]
toLobster subattributes policy0 = do
  let patternMacros =
        -- We handle domtrans_pattern macro as a special case, for now
        Map.delete (S.mkId "domtrans_pattern") $
        Map.fromList
          [ (i, reverse stmts) | SupportDef i stmts <- supportDefs policy0 ]
        -- ^ Policy pattern macros are parsed with statements in reverse order
  let interfaceMacros =
        Map.fromList
          [ (i, stmts)
          | m <- policyModules policy0
          , InterfaceElement InterfaceType _doc i stmts <- interfaceElements (interface m) ]
  let templateMacros =
        Map.fromList
          [ (i, stmts)
          | m <- policyModules policy0
          , InterfaceElement TemplateType _doc i stmts <- interfaceElements (interface m) ]
  let classSetMacros =
        Map.fromList
          [ (i, toList ids)
          | ClassPermissionDef i ids _ <- classPermissionDefs policy0 ]
  let macros = Macros (Map.unions [patternMacros, interfaceMacros, templateMacros]) classSetMacros
  let modules = map (expandPolicyModule macros) (policyModules policy0)
  let policy = policy0 { policyModules = modules }
  let action = processPolicy modules >> processAttributes >> processSubAttributes subattributes
  let (subattrs, finalSt) = runState (runReaderT action initEnv) initSt
  return (outputLobster policy (finalSt, subattrs))

toLobsterModule :: [SubAttribute] -> PolicyModule -> Either Error [L.Decl]
toLobsterModule subattributes policyModule = do
  let iface = interfaceElements (interface policyModule)
  let patternMacros = Map.empty  -- TODO
  let interfaceMacros =
        Map.fromList
          [ (i, stmts)
          | InterfaceElement InterfaceType _doc i stmts <- iface ]
  let templateMacros =
        Map.fromList
          [ (i, stmts)
          | InterfaceElement TemplateType _doc i stmts <- iface ]
  let classSetMacros = Map.empty  -- TODO
  let macros = Macros (Map.unions [patternMacros, interfaceMacros, templateMacros]) classSetMacros
  let modules = [expandPolicyModule macros policyModule]
  let action = processPolicy modules >> processAttributes >> processSubAttributes subattributes
  let (subattrs, finalSt) = runState (runReaderT action initEnv) initSt
  return (outputLobster undefined (finalSt, subattrs))

capitalize :: String -> String
capitalize "" = ""
capitalize (x:xs) = toUpper x : xs

lowercase :: String -> String
lowercase "domain" = "domain_type" -- FIXME: ugly hack
lowercase "" = ""
lowercase (x:xs) = toLower x : xs
