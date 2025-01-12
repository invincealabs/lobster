{-# OPTIONS -Wall -Werror #-}
-- | A variation of M4ToLobster where we only generate one Lobster
-- domain per SELinux security type; the domain includes one port for
-- each SELinux class used with that type. Permission sets are
-- encoded as edge annotations.
module M4ToLobster2 where
-- FIXME: rename module

import Control.Error
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Char
import Data.Foldable (toList)
import Data.List (isSuffixOf)
import Data.Map (Map)
import Data.Set (Set)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.MapSet as MapSet

import SCD.M4.PrettyPrint ()
import SCD.M4.Syntax hiding (avPerms)
import qualified SCD.M4.Syntax as M4

import qualified SCD.SELinux.Syntax as S
import qualified Text.Happy.ParserMonad as P

import qualified SCD.Lobster.Gen.CoreSyn as L

import SCD.M4.Subst (Macros(..), expandPolicyModule)

import M4ToLobster.Error

----------------------------------------------------------------------
-- State monad

data AllowRule = AllowRule 
  { allowSubject    :: S.TypeOrAttributeId
  , allowObject     :: S.TypeOrAttributeId
  , allowClass      :: S.ClassId
  } deriving (Eq, Ord, Show)

data St = St
  { object_classes   :: !(Map S.TypeOrAttributeId (Set S.ClassId))
  , attrib_members   :: !(Map S.AttributeId (Set S.TypeId))
  , allow_rules      :: !(Map AllowRule (Map S.PermissionId (Set P.Pos)))
  , type_transitions :: !(Set (S.TypeId, S.TypeId, S.ClassId, S.TypeId))
  , domtrans_macros  :: !(Set (S.TypeOrAttributeId, S.TypeOrAttributeId, S.TypeOrAttributeId))
  }

processClassId :: S.ClassId
processClassId = S.mkId "process"

activePermissionId :: S.PermissionId
activePermissionId = S.mkId "active"

initSt :: St
initSt = St
  { object_classes   = Map.empty
  , attrib_members   = Map.empty
  , allow_rules      = Map.empty
  , type_transitions = Set.empty
  , domtrans_macros  = Set.empty
  }

type M a = ReaderT [P.Pos] (State St) a

----------------------------------------------------------------------
-- Processing of M4 policy

filterSignedId :: Eq a => [S.SignedId a] -> [a]
filterSignedId xs = [ y | y <- ys, y `notElem` zs ]
  where
    (ys, zs) = partitionEithers (map f xs)
    f (S.SignedId S.Positive y) = Left y
    f (S.SignedId S.Negative z) = Right z

fromSelf :: S.TypeOrAttributeId -> S.Self -> S.TypeOrAttributeId
fromSelf x S.Self = x
fromSelf _ (S.NotSelf x) = x

insertMapSet :: (Ord k, Ord a) => k -> a -> Map k (Set a) -> Map k (Set a)
insertMapSet k x = Map.insertWith (flip Set.union) k (Set.singleton x)

addkeyMapSet :: (Ord k, Ord a) => k -> Map k (Set a) -> Map k (Set a)
addkeyMapSet = Map.alter (maybe (Just Set.empty) Just)

addAllow :: S.TypeOrAttributeId -> S.TypeOrAttributeId
         -> S.ClassId -> Set S.PermissionId -> M ()
addAllow subject object cls perms = do
  -- discard all but the outermost enclosing source position
  -- so that we only get the position of the top-level macro
  ps <- asks (Set.fromList . take 1 . reverse)
  let m = Map.fromSet (const ps) perms
  modify (f m)
  where
    rule = AllowRule subject object cls
    f m st = st
      { object_classes =
          insertMapSet subject processClassId $
          insertMapSet object cls $
          object_classes st
      , allow_rules = Map.insertWith (Map.unionWith Set.union) rule m (allow_rules st)
      }

addType :: S.TypeId -> M ()
addType ty = modify f
  where
    f st = st
      { object_classes = addkeyMapSet (S.fromId (S.toId ty)) (object_classes st) }

addAttrib :: S.TypeId -> S.AttributeId -> M ()
addAttrib ty attr = modify f
  where
    f st = st
      { object_classes = addkeyMapSet (S.fromId (S.toId attr)) (object_classes st)
      , attrib_members = insertMapSet attr ty (attrib_members st)
      }

addAttribs :: S.TypeId -> [S.AttributeId] -> M ()
addAttribs ty attrs = mapM_ (addAttrib ty) attrs

addTypeTransition :: S.TypeId -> S.TypeId -> S.ClassId -> S.TypeId -> M ()
addTypeTransition subj rel cls new = modify f
  where
    f st = st
      { object_classes =
          insertMapSet (S.fromId (S.toId new)) cls $
          object_classes st
      , type_transitions = Set.insert (subj, rel, cls, new) (type_transitions st)
      }

addDomtransMacro :: S.TypeOrAttributeId -> S.TypeOrAttributeId -> S.TypeOrAttributeId -> M ()
addDomtransMacro d1 d2 d3 = modify f
  where
    f st = st
      { object_classes =
          insertMapSet d1 processClassId $
          insertMapSet d1 (S.mkId "fd") $
          insertMapSet d1 (S.mkId "fifo_file") $
          insertMapSet d2 (S.mkId "file") $
          insertMapSet d3 processClassId $
          object_classes st
      , attrib_members = attrib_members st
      , domtrans_macros = Set.insert (d1, d2, d3) (domtrans_macros st)
      }

isDefined :: M4.IfdefId -> Bool
isDefined _ = False
-- ^ FIXME: make this depend on a parameter

processStmts :: M4.Stmts -> M ()
processStmts = mapM_ processStmt

processStmt :: M4.Stmt -> M ()
processStmt stmt =
  case stmt of
    Ifdef i stmts1 stmts2 -> processStmts (if isDefined i then stmts1 else stmts2)
    Ifndef i stmts -> processStmts (if isDefined i then [] else stmts)
    Type t _aliases attrs -> addType t >> addAttribs t attrs -- TODO: track aliases
    TypeAttribute t attrs -> addAttribs t (toList attrs)
    Transition S.TypeTransition (S.SourceTarget al bl cl) t ->
      sequence_ $
        [ addTypeTransition subject related classId object
        | let object = (S.fromId . S.toId) t
        , subject <- map (S.fromId . S.toId) $ filterSignedId $ toList al
        , related <- map (S.fromId . S.toId) $ filterSignedId $ toList bl
        , classId <- toList cl
        ]
    TeAvTab S.Allow (S.SourceTarget al bl cl) (S.Permissions dl) ->
      sequence_ $
        [ addAllow subject object classId perms
        | subject <- filterSignedId $ toList al
        , object' <- filterSignedId $ toList bl
        , let object = fromSelf subject object'
        , classId <- toList cl
        , let perms = Set.fromList $ toList dl
        ]
    StmtPosition stmt1 pos -> local (pos :) $ processStmt stmt1
    Call m4id [al, bl, cl] | m4id == S.mkId "domtrans_pattern" ->
      sequence_ $
        [ addDomtransMacro a b c
        | a <- map (S.fromId . S.toId) $ filterSignedId $ toList al
        , b <- map (S.fromId . S.toId) $ filterSignedId $ toList bl
        , c <- map (S.fromId . S.toId) $ filterSignedId $ toList cl
        ]
    _ -> return ()

processImplementation :: M4.Implementation -> M ()
processImplementation (M4.Implementation _ _ stmts) = mapM_ processStmt stmts

processPolicyModule :: M4.PolicyModule -> M ()
processPolicyModule m = processImplementation (M4.implementation m)

processPolicy :: M4.Policy -> M ()
processPolicy policy = mapM_ processPolicyModule (M4.policyModules policy)

----------------------------------------------------------------------
-- Sub-attributes

-- TODO: read these in from a file
subattributes :: [(S.AttributeId, S.AttributeId)]
subattributes = [ (S.mkId a, S.mkId b) | (a, b) <- attrs ]
  where
    attrs =
      [ ("client_packet_type", "packet_type")
      , ("server_packet_type", "packet_type")
      , ("defined_port_type", "port_type")
      , ("reserved_port_type", "port_type")
      , ("unreserved_port_type", "port_type")
      , ("rpc_port_type", "reserved_port_type")
      , ("non_auth_file_type", "file_type")
      , ("non_security_file_type", "non_auth_file_type")
      , ("httpdcontent", "non_security_file_type")
      , ("lockfile", "non_security_file_type")
      , ("pidfile", "non_security_file_type")
      ]

-- Checking and removal of redundant edges for sub-attribute membership
processSubAttributes :: [(S.AttributeId, S.AttributeId)] -> M Bool
processSubAttributes subs = do
  st <- get
  let m0 = attrib_members st
  -- TODO: use error monad instead of returning Bool.
  let check (a, b) (m, ok) = (m', ok')
        where
          xs = MapSet.lookup a m0
          ys = MapSet.lookup b m0
          m' = Map.insert b (Set.difference (MapSet.lookup b m) xs) m
          ok' = ok && Set.isSubsetOf xs ys
  let (mf, ok) = foldr check (m0, True) subs
  put $ st { attrib_members = mf }
  return ok


----------------------------------------------------------------------
-- Generation of Lobster code

type Dom = L.Name
type Port = L.Name

activePort :: Port
activePort = L.Name "active"

memberPort :: Port
memberPort = L.Name "member"

attributePort :: Port
attributePort = L.Name "attribute"

toDom :: S.IsIdentifier i => i -> Dom
toDom = L.Name . lowercase . S.idString

toPort :: S.IsIdentifier i => i -> Port
toPort = L.Name . lowercase . S.idString

outputPerm :: S.PermissionId -> L.ConnectAnnotation
outputPerm p = L.ConnectAnnotation (L.Name "Perm") [L.AnnotationString (S.idString p)]

outputPos :: P.Pos -> L.ConnectAnnotation
outputPos (P.Pos fname _ l c) =
  L.ConnectAnnotation (L.Name "SourcePos")
    [L.AnnotationString fname, L.AnnotationInt l, L.AnnotationInt c]

outputAllowRule :: (AllowRule, Map S.PermissionId (Set P.Pos)) -> L.Decl
outputAllowRule (AllowRule subject object cls, m) =
  L.connect' L.N
    (L.domPort (toDom subject) activePort)
    (L.domPort (toDom object) (toPort cls))
    (map outputPerm perms ++ map outputPos ps)
  where
    perms = Map.keys m
    ps = Set.toList (Set.unions (Map.elems m))

outputAttribute :: S.TypeId -> S.AttributeId -> L.Decl
outputAttribute ty attr =
  L.connect' L.N
    (L.domPort (toDom ty) memberPort)
    (L.domPort (toDom attr) attributePort)
    [L.ConnectAnnotation (L.Name "Attribute") []]

outputSubAttribute :: S.AttributeId -> S.AttributeId -> L.Decl
outputSubAttribute ty attr =
  L.connect' L.N
    (L.domPort (toDom ty) memberPort)
    (L.domPort (toDom attr) attributePort)
    [L.ConnectAnnotation (L.Name "SubAttribute") []]

outputTypeTransition :: (S.TypeId, S.TypeId, S.ClassId, S.TypeId) -> L.Decl
outputTypeTransition (subj, rel, cls, new) =
  L.connect' L.N
    (L.domPort (toDom subj) activePort)
    (L.domPort (toDom new) (toPort cls))
    [L.ConnectAnnotation (L.Name "TypeTransition") [L.AnnotationString (S.idString rel)]]

outputDomtransMacro ::
  Int -> (S.TypeOrAttributeId, S.TypeOrAttributeId, S.TypeOrAttributeId) -> [L.Decl]
outputDomtransMacro n (d1, d2, d3) =
  [ L.Domain d (L.Name "Domtrans_pattern") [L.Name (show (S.idString d2))]
  , connect
      (L.domPort (toDom d1) activePort)
      (L.domPort d (L.Name "d1_active"))
  , connect
      (L.domPort (toDom d1) (L.Name "fd"))
      (L.domPort d (L.Name "d1_fd"))
  , connect
      (L.domPort (toDom d1) (L.Name "fifo_file"))
      (L.domPort d (L.Name "d1_fifo_file"))
  , connect
      (L.domPort (toDom d1) (L.Name "process"))
      (L.domPort d (L.Name "d1_process"))
  , connect
      (L.domPort (toDom d2) (L.Name "file"))
      (L.domPort d (L.Name "d2_file"))
  , connect
      (L.domPort (toDom d3) activePort)
      (L.domPort d (L.Name "d3_active"))
  , connect
      (L.domPort (toDom d3) (L.Name "process"))
      (L.domPort d (L.Name "d3_process"))
  ]
  where
    d :: Dom
    d = L.Name ("domtrans" ++ show n)

    connect :: L.DomPort -> L.DomPort -> L.Decl
    connect x y = L.connect' L.N x y [L.ConnectAnnotation (L.Name "MacroArg") []]

outputLobster :: St -> [L.Decl]
outputLobster st =
  domtransDecl :
  domainDecls ++ connectionDecls ++ attributeDecls ++ subAttributeDecls
    ++ transitionDecls ++ domtransDecls
  where
    domainDecl :: (S.TypeOrAttributeId, Set S.ClassId) -> [L.Decl]
    domainDecl (ty, classes) =
      [ L.Class className [] (header ++ stmts)
      , L.Domain (toDom ty) className [] ]
        -- TODO: Add support for anonymous domains to lobster language
      where
        className = L.Name ("Type_" ++ S.idString ty)
        header = map L.newPort [activePort, memberPort, attributePort]
        stmts = [ L.newPort (toPort c) | c <- Set.toList classes ]

    domainDecls :: [L.Decl]
    domainDecls = concatMap domainDecl (Map.assocs (object_classes st))

    connectionDecls :: [L.Decl]
    connectionDecls = map outputAllowRule (Map.assocs (allow_rules st))

    attributeDecls :: [L.Decl]
    attributeDecls = do
      (attr, tys) <- Map.assocs (attrib_members st)
      [ outputAttribute ty attr | ty <- Set.toList tys ]

    subAttributeDecls :: [L.Decl]
    subAttributeDecls =
      [ outputSubAttribute sub sup | (sub, sup) <- subattributes ]

    transitionDecls :: [L.Decl]
    transitionDecls = map outputTypeTransition (Set.toList (type_transitions st))

    domtransDecls :: [L.Decl]
    domtransDecls = concat $ zipWith outputDomtransMacro [1..] (Set.toList (domtrans_macros st))

    domtransDecl :: L.Decl
    domtransDecl =
      L.Class (L.Name "Domtrans_pattern") [d2_name]
        [ L.newPort d1_active
        , L.newPort d1_fd
        , L.newPort d1_fifo
        , L.newPort d1_proc
        , L.newPort d2_file
        , L.newPort d3_active
        , L.newPort d3_proc
        , L.connect' L.N (L.extPort d1_active) (L.extPort d2_file)
            [outputPerm (S.mkId "x_file_perms")]
        , L.connect' L.N (L.extPort d1_active) (L.extPort d3_proc)
            [outputPerm (S.mkId "transition"),
             L.ConnectAnnotation (L.Name "TypeTransition") [L.AnnotationVar d2_name]]
        , L.connect' L.N (L.extPort d3_active) (L.extPort d1_fd)
            [outputPerm (S.mkId "use")]
        , L.connect' L.N (L.extPort d3_active) (L.extPort d1_fifo)
            [outputPerm (S.mkId "rw_fifo_file_perms")]
        , L.connect' L.N (L.extPort d3_active) (L.extPort d1_proc)
            [outputPerm (S.mkId "sigchld")]
        ]
      where
        d1_active = L.Name "d1_active"
        d1_fd     = L.Name "d1_fd"
        d1_fifo   = L.Name "d1_fifo_file"
        d1_proc   = L.Name "d1_process"
        d2_file   = L.Name "d2_file"
        d3_active = L.Name "d3_active"
        d3_proc   = L.Name "d3_process"
        d2_name   = L.Name "d2_name"

----------------------------------------------------------------------

-- | Convert a policy to Lobster.
toLobster :: Policy -> Either Error [L.Decl]
toLobster policy0 = do
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
          | ClassPermissionDef i ids _ <- classPermissionDefs policy0
          , "_class_set" `isSuffixOf` S.idString i ]
  let macros = Macros (Map.unions [patternMacros, interfaceMacros, templateMacros]) classSetMacros
  let policy = policy0 { policyModules = map (expandPolicyModule macros) (policyModules policy0) }
  let action = processPolicy policy >> processSubAttributes subattributes
  let (ok, finalSt) = runState (runReaderT action []) initSt
  if ok
    then return (outputLobster finalSt)
    else Left (Error "subattribute check failed")

lowercase :: String -> String
lowercase "domain" = "domain_type" -- FIXME: ugly hack
lowercase "" = ""
lowercase (x:xs) = toLower x : xs
