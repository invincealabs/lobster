{-# OPTIONS -Wall #-}
module Main (main) where

import Control.Monad.State
import Data.Char
import Data.List
import Data.Map (Map)
import Data.Maybe
import Data.NonEmptyList(NonEmptyList)
import Data.Foldable(toList)
import Debug.Trace
import SCD.M4.ModuleFiles
import SCD.M4.PrettyPrint ()
import SCD.M4.Syntax hiding (avPerms)
import System.Console.GetOpt
import System.Directory
import System.Environment
import System.Exit
import Text.PrettyPrint.HughesPJ
import Text.PrettyPrint.Pp
import qualified Data.Map as Map

-- import Data.Set (Set)
-- import SCD.M4.Kind
-- import SCD.M4.KindCheck
-- import SCD.M4.KindCheckPolicy(errorDoc)
-- import qualified Data.Set as Set
-- import qualified SCD.M4.Options as O
import qualified SCD.SELinux.Syntax as S

-- Simple state monad for traversing the policy and kind information
type M a = State St a
type N a = State LModule a

data St = St
  { stImplementations :: [String]
  , stTemplates :: [String]
  , stInterfaces :: [String]
  , stTypes :: [(String,String)]
  , stCalls :: [(String,Call)]
  , stRequires :: [(String,String)]
  , stAllows :: [(String,Allow)]
  , stFCs :: [(String,String)]
  } deriving Show

type Call = (String,[String])
type Allow = (String,String,String,String)

-- Simplified data type for lobster modules
data LModule = LModule
  { mClasses :: Map String LClass
  , mDomains :: Map String DomainType
  } deriving Show

-- Simplified data type for lobster classes
data LClass = LClass
  { ports :: [String]
  , domains :: Map String DomainType
  , connections :: [Connection]
  } deriving Show

type DomainType = (String,[String])

type Connection = (String,String,String,String)

main :: IO ()
main = do
  args <- getArgs
  (opts, iDir) <- checkOpt_ args
--  let shrimpOpts = O.defaultOptions{ O.ifdefDeclFile = ifdefDeclFile opts}
  policy0 <- readPolicy (ifdefDeclFile opts) iDir
--   let
--     kcOpts = if kindErrors opts then defaultKindCheckOptions else ignoreErrorsKindCheckOptions
--     (ki, errs) = kcPolicy shrimpOpts kcOpts policy []
--   when ((not $ null errs) && kindErrors opts) $ do
--     let (d,_) = errorDoc shrimpOpts errs
--     reportErrors [render d]
  let patterns = Map.fromList [ (i, stmts) | SupportDef i stmts <- supportDefs policy0 ]
  let policy = policy0 { policyModules = map (expandPolicyModule patterns) (policyModules policy0) }
  processPolicy opts policy

type Macros = Map M4Id [Stmt]

expandPolicyModule :: Macros -> PolicyModule -> PolicyModule
expandPolicyModule s pm =
  pm { interface = expandInterface s (interface pm)
     , implementation = expandImplementation s (implementation pm)
     }

expandImplementation :: Macros -> Implementation -> Implementation
expandImplementation s (Implementation i v stmts) = Implementation i v (expandStmts s stmts)

expandInterface :: Macros -> Interface -> Interface
expandInterface s (InterfaceModule doc es) = InterfaceModule doc (map (expandInterfaceElement s) es)

expandInterfaceElement :: Macros -> InterfaceElement -> InterfaceElement
expandInterfaceElement s (InterfaceElement ty doc i stmts) =
  InterfaceElement ty doc i (expandStmts s stmts)

expandStmts :: Macros -> Stmts -> Stmts
expandStmts s stmts = concatMap (expandStmt s) stmts

expandStmt :: Macros -> Stmt -> [Stmt]
expandStmt s stmt =
  case stmt of
    Tunable cond stmts1 stmts2  -> [Tunable cond (expandStmts s stmts1) (expandStmts s stmts2)]
    Optional stmts1 stmts2      -> [Optional (expandStmts s stmts1) (expandStmts s stmts2)]
    Ifdef i stmts1 stmts2       -> [Ifdef i (expandStmts s stmts1) (expandStmts s stmts2)]
    Ifndef i stmts              -> [Ifndef i (expandStmts s stmts)]
    CondStmt cond stmts1 stmts2 -> [CondStmt cond (expandStmts s stmts1) (expandStmts s stmts2)]
    Call i args -> -- args :: [NonEmptyList (SignedId Identifier)]
      case Map.lookup i s of
        Nothing -> [stmt]
        Just stmts -> expandStmts s $ map (substStmt args) (reverse stmts)
                      -- ^ Policy macros are parsed with statements in reverse order
    _ -> [stmt]

substStmt :: [NonEmptyList (S.SignedId S.Identifier)] -> Stmt -> Stmt
substStmt xs stmt =
  case stmt of
    Transition t (S.SourceTarget st tt tc) i ->
        Transition t (S.SourceTarget (substSourceTypes st) (substSourceTypes tt) (substTargetClasses tc)) (fromSingle $ substId' i)
    TeAvTab a (S.SourceTarget st tt tc) perms ->
        TeAvTab a (S.SourceTarget (substSourceTypes st) (substTargetTypes tt) (substTargetClasses tc))
                    (substPermissions perms)
    -- TeAvTab (allow rules)
    Call i args -> Call i (map substArg args)
    _ -> stmt
  where
    substSourceTypes :: NonEmptyList (S.SignedId S.TypeOrAttributeId) -> NonEmptyList (S.SignedId S.TypeOrAttributeId)
    substSourceTypes st = substSignedId =<< st

    substTargetTypes :: NonEmptyList (S.SignedId S.Self) -> NonEmptyList (S.SignedId S.Self)
    substTargetTypes tt = substSignedIdSelf =<< tt

    substTargetClasses :: NonEmptyList S.ClassId -> NonEmptyList S.ClassId
    substTargetClasses tc = substId' =<< tc

    substArg :: NonEmptyList (S.SignedId S.Identifier) -> NonEmptyList (S.SignedId S.Identifier)
    substArg arg = substSignedId =<< arg

    substSignedId :: S.IsIdentifier i => S.SignedId i -> NonEmptyList (S.SignedId i)
    substSignedId (S.SignedId S.Positive i) = substId i
    substSignedId (S.SignedId S.Negative i) = fmap negateSignedId (substId i)

    substSignedIdSelf :: S.SignedId S.Self -> NonEmptyList (S.SignedId S.Self)
    substSignedIdSelf (S.SignedId S.Positive self) = substSelf self
    substSignedIdSelf (S.SignedId S.Negative self) = fmap negateSignedId (substSelf self)

    substSelf :: S.Self -> NonEmptyList (S.SignedId S.Self)
    substSelf S.Self = return (S.SignedId S.Positive S.Self)
    substSelf (S.NotSelf i) = fmap (fmap S.NotSelf) (substId i)

    substId :: S.IsIdentifier i => i -> NonEmptyList (S.SignedId i)
    substId i =
      case asDollar (S.idString i) of
        Nothing -> return (S.SignedId S.Positive i)
        Just n -> fmap (fmap S.fromId) (xs !! (n - 1))

    asDollar :: String -> Maybe Int
    asDollar ('$' : s)
      | all isDigit s = let n = read s in if n <= length xs then Just n else Nothing
    asDollar _ = Nothing

    substId' :: S.IsIdentifier i => i -> NonEmptyList i
    substId' i = fmap fromPositive (substId i)

    fromPositive :: S.SignedId a -> a
    fromPositive (S.SignedId S.Positive x) = x
    fromPositive (S.SignedId S.Negative _) = error "fromPositive"

    fromSingle :: NonEmptyList a -> a
    fromSingle ys =
      case toList ys of
        [y] -> y
        _ -> error "fromSingle"

    negateSignedId :: S.SignedId a -> S.SignedId a
    negateSignedId (S.SignedId S.Positive x) = S.SignedId S.Negative x
    negateSignedId (S.SignedId S.Negative _) = error "negateSignedId Negative"

    substPermissions :: S.Permissions -> S.Permissions
    substPermissions (S.Permissions pids) = S.Permissions (substId' =<< pids)
    substPermissions (S.PStarTilde _) = error "substPermissions PStarTilde"


-- option handling

data Options = Options
  { path :: FilePath
  , isDir :: Bool
  , ifdefDeclFile :: Maybe FilePath
  , inferMissing :: Bool
--   , kindErrors :: Bool
  } deriving Show

-- | Default options for reference policy processing
defaultOptions :: Options
defaultOptions = Options
  { path = "Gen_Lobster_Dir"
  , isDir = True
  , ifdefDeclFile = Nothing
  , inferMissing = False
--   , kindErrors = False
  }

options :: [OptDescr (Options -> Options)]
options =
  [ Option [] ["multiple"] (ReqArg (\a o -> o{ path = a, isDir = True }) "FILE") ""
  , Option [] ["single"] (ReqArg (\a o -> o{ path = a, isDir = False }) "FILE") ""
  , Option [] ["infer-missing"] (NoArg (\o -> o{ inferMissing = True })) ""
  , Option [] ["ifdefs"] (ReqArg (\f o -> o{ ifdefDeclFile = Just f }) "FILE") ""
--   , Option [] ["kind-errors"] (NoArg (\o -> o{ kindErrors = True })) ""
  ]

printUsage :: IO ()
printUsage = do
  p <- getProgName
  putStrLn $ unlines $
    [ "Usage:"
    , p ++ "[global options] <input directory>"
    , "  Generate lobster policy module(s) from selinux policy in <input directory>"
    , "Global options:"
    , "--single <file>    Place all lobster definitions in a single <file>"
    , "--multiple <dir>   Generate multiple lobster files and place them in <dir>"
    , "--ifdefs <file>    Read ifdef declarations from <file>"
    , "--infer-missing    infer missing classes (suitable for graphing by lviz)"
--     , "--kind-errors      Output errors generated by kind checking"
    ]

-- policy and kind information traversal

processPolicy :: Options -> Policy -> IO ()
processPolicy opts x = do
  f <- if isDir opts
    then do
      let dir = path opts
      createDirectoryIfMissing True dir
      return $ \fn s -> do
        writeFile fn s
        appendFile fn "\n"
    else do
      let fn = path opts
      writeFile fn ""
      return $ \_ s -> appendFile fn s
  mapM_ (processPolicyModule f opts) $ policyModules x

processPolicyModule :: (FilePath -> String -> IO ()) -> Options -> PolicyModule -> IO ()
processPolicyModule f opts x = do
  let
    dir = path opts
    fn = dir ++ "/" ++ baseName x ++ ".lsr"
    st = execM $ do
      processImplementation $ implementation x
      processInterface $ interface x
      processFileContexts $ fileContexts x
    m = execN $ stToLModule opts st
  f fn $ render $ ppLModule m

processImplementation :: Implementation -> M ()
processImplementation (Implementation mId _ stmts) = do
  initImplementation n
  mapM_ (processStmt n) stmts
  where n = show (pp mId) ++ "_te" -- fixme: make sure no name conflicts

processInterface :: Interface -> M ()
processInterface x = do
  mapM_ processInterfaceElement $ interfaceElements x

processInterfaceElement :: InterfaceElement -> M ()
processInterfaceElement (InterfaceElement ty _doc m4Id stmts) = do
  case ty of
--  TemplateType | show (pp m4Id) == "a_b" -> do
    TemplateType -> initTemplate n
    InterfaceType -> initInterface n
  mapM_ (processStmt n) stmts
  where n = show $ pp m4Id

processStmt :: String -> Stmt -> M ()
processStmt n x = case x of
  Type a [] [] -> do
    let y = show $ pp a
    addType n y
  Call a b -> do
    let y = show $ pp a
    let cs = map (show . pp) $ concatMap toList b
    addCall n (y,cs)
  Require a -> mapM_ (processRequire n) $ toList a
  TeAvTab S.Allow (S.SourceTarget al bl cl) (S.Permissions dl) ->
    mapM_ (addAllow n) $ [ (a,b,c,d) | a <- f al, b <- f bl, c <- f cl, d <- f dl ]
    where
    f :: Pp a => NonEmptyList a -> [String]
    f = map (show . pp) . toList
  _ -> warnPat "processStmt" $ show x

processRequire :: String -> Require -> M ()
processRequire n x = case x of
  RequireType a -> do
    mapM_ (addRequire n) $ map (show . pp) $ toList a
  _ -> warnPat "processRequire" $ show x

processFileContexts :: FileContexts -> M ()
processFileContexts (FileContexts xs) = mapM_ processFileContext xs

processFileContext :: FileContext -> M ()
processFileContext x = case x of
  FileContext a Nothing (Just (GenContext _ _ b _)) -> addFC (show $ pp b) (show $ pp a)
  _ -> warnPat "processFileContext" (show $ pp x)

-- processKindInfo :: KindInfo -> M ()
-- processKindInfo (KindInfo _ifcEnv mEnv impEnv _ixRefs _parmMap) = do
--   processM4Env mEnv
--   processImplementationEnv impEnv

-- processM4Env :: (S.IsIdentifier k) => Map k M4Info -> M ()
-- processM4Env x = sequence_ [ processM4Info (S.idString a) b | (a,b) <- Map.toList x ]

-- processM4Info :: String -> M4Info -> M ()
-- processM4Info a b = case b of
--   M4Macro x -> processInterfaceEnv a x
--   M4IdSet _ _ _ -> return ()
--   M4Ifdef _ -> return ()

-- processInterfaceEnv :: String -> InterfaceEnv -> M ()
-- processInterfaceEnv a b = processKindMaps a $ kindMaps b

-- processImplementationEnv :: (S.IsIdentifier k) => Map k KindMaps -> M ()
-- processImplementationEnv x =
--   sequence_ [ processKindMaps (S.idString a) b | (a,b) <- Map.toList x ]

-- processKindMaps :: String -> KindMaps -> M ()
-- processKindMaps a b = do
--   when (not $ null outputs) $ do
--     initDomain a
--     mapM_ (processOutputs a) outputs
--   mapM_ (processAllows inputs) $ Map.toList $ allowMap b
--   where
--   inputs = [ (S.idString n, a ++ i) | (n,i) <- zip ns ("" : map show [ 2 :: Int .. ]) ]
--   ns = map fst $ Map.toList (inputMap b) ++ Map.toList (iInputMap b)
--   outputs = Map.toList (outputMap b) ++ Map.toList (iOutputMap b)

-- processOutputs :: String -> (S.Identifier, Set PosKind) -> M ()
-- processOutputs a (b,c) = do
--   fcs <- getFCs
--   let
--     es = case lookup v fcs of
--       Nothing -> []
--       Just fn -> [show fn]
--     ty = if null [ x | x@(PosKind _ DomainKind) <- Set.toList c ] then "File" else "Process"
--   addDomain a (v,(ty,es))
--   where
--   v = stripDollar $ S.idString b

-- processAllows :: [(String,String)] -> (S.Identifier, Set AllowInfo) -> M ()
-- processAllows inputs (a,b) = mapM_ (processAllowInfo inputs $ S.idString a) $ Set.toList b

-- processAllowInfo :: [(String,String)] -> String -> AllowInfo -> M ()
-- processAllowInfo inputs a b = case avPerms b of
--   [] -> addAllow (x, y, z, Nothing)
--   xs -> mapM_ f xs
--   where
--   f c = addAllow (x, y, z, Just $ S.idString c)
--   (x,y) = (stripDollar $ fromMaybe a $ lookup a inputs, stripDollar $ S.idString $ avTarget b)
--   z = map (capitalize . S.idString) $ avClasses b

-- state monad functions

execM :: M () -> St
execM = flip execState initSt

execN :: N () -> LModule
execN = flip execState initLModule

initSt :: St
initSt = St [] [] [] [] [] [] [] []

initLModule :: LModule
initLModule = LModule Map.empty Map.empty

initImplementation :: String -> M ()
initImplementation a = modify $ \st -> st{ stImplementations = ins a $ stImplementations st }

initTemplate :: String -> M ()
initTemplate a = modify $ \st -> st{ stTemplates = ins a $ stTemplates st }

initInterface :: String -> M ()
initInterface a = modify $ \st -> st{ stInterfaces = ins a $ stInterfaces st }

addType :: String -> String -> M ()
addType a b = modify $ \st -> st{ stTypes = ins (a,b) $ stTypes st }

addCall :: String -> Call -> M ()
addCall a b = modify $ \st -> st{ stCalls = ins (a,b) $ stCalls st }

addRequire :: String -> String -> M ()
addRequire a b = modify $ \st -> st{ stRequires = ins (a,b) $ stRequires st }

addAllow :: String -> Allow -> M ()
addAllow a b = modify $ \st -> st{ stAllows = ins (a,b) $ stAllows st }

addFC :: String -> String -> M ()
addFC a b = modify $ \st -> st{ stFCs = ins (a,b) $ stFCs st }

-- St to LModule

stToLModule :: Options -> St -> N ()
stToLModule opts st = do
  mapM_ initClass $ stTemplates st ++ stImplementations st
  mapM_ initDomain $ stTypes st
  mapM_ inferDomainType $
    (concatMap domainTypesAllow $ stAllows st) ++ (map domainTypeFC $ stFCs st)
  mapM_ addConnection $ stAllows st
  mapM_ (inferCallDomain $ stRequires st) $ stCalls st
  mapM_ (addCallConnections $ stAllows st) $ stCalls st
  when (inferMissing opts) $ do
    cls <- liftM inferClasses $ gets mClasses
    modify $ \m -> m{ mClasses = Map.union cls (mClasses m) }
    modify $ \m -> m{ mDomains = Map.fromList [ (s, (userDT s)) | s <- Map.keys $ mClasses m ] }

inferCallDomain :: [(String,String)] -> (String,Call) -> N ()
inferCallDomain _ (a,(b,[])) = warn $ "unhandled empty call:" ++ a ++ ":" ++ b
inferCallDomain reqs (a,(b,(c:_))) = do
  xs <- gets mClasses
  case (Map.lookup a xs, Map.lookup b xs) of
    (Just x, Just _) ->
      insertClass a (x{ domains = Map.insert c1 (userDT b) $ domains x
                      , connections = nub (conns ++ connections x)
                      , ports = nub (ps ++ ports x)
                      })
      where
      (ps,conns) = unzip [ let p = ra ++ "_" ++ rb in (p,(p,"",c1,rb))
                           | (ra,rb) <- reqs, ra == b ]
    _ -> return ()
  where
  c1 = stripDollar c

addCallConnections :: [(String,Allow)] -> (String,Call) -> N ()
addCallConnections xs (a,(b,[c,_])) = do
  cls <- gets mClasses
  case Map.lookup a cls of
    Just cl ->
      insertClass a (cl{ connections = nub (conns ++ connections cl)
                       , ports = ins a $ ports cl
                       })
      where
      conns = catMaybes [ f y | (x,(y,_,_,_)) <- xs, x == b ]
      f y | stripDollar y == "" = Just (a,"",c1,b)
      f _ = Nothing
    _ -> return ()
  where
  c1 = stripDollar c
addCallConnections _ (_,(_,_)) = return ()

addConnection :: (String,Allow) -> N ()
addConnection a = modify $ \st -> st{ mClasses = Map.map (addAllowConn a) $ mClasses st }

addAllowConn :: (String,Allow) -> LClass -> LClass
addAllowConn (a,(b,c,_,d)) x = case (Map.lookup c1 $ domains x, Map.lookup b1 $ domains x) of
  (Just _, Just _) -> x{ connections = ins (b1,"active",c1,d) $ connections x }
  (Just _, _) -> x{ ports = ins p $ ports x
                  , connections = ins (p,"",c1,d) $ connections x
                  }
    where p = substDollar a b
  (_, Just _) -> x{ ports = ins p $ ports x
                  , connections = ins (b1,"active",p,"") $ connections x
                  }
    where p = substDollar a c
  _ -> x
  where
  c1 = stripDollar c
  b1 = stripDollar b
  
initClass :: String -> N ()
initClass x = insertClass x initLClass

insertClass :: String -> LClass -> N ()
insertClass a b = modify $ \m -> m{ mClasses = Map.insert a b $ mClasses m }

initDomain :: (String,String) -> N ()
initDomain (a,b0) = do
  let b = stripDollar b0
  cs <- gets mClasses
  case Map.lookup a cs of
    Just c -> case Map.lookup b $ domains c of
      Nothing -> insertClass a (c{ domains = Map.insert b unknownDT $ domains c })
      Just _ -> error $ "type redeclared:" ++ show b
    Nothing -> error $ "unknown class:" ++ a

userDT :: String -> DomainType
userDT s = (s,[])

unknownDT :: DomainType
unknownDT = ("unknown",[])

inferDomainType :: (String,DomainType) -> N ()
inferDomainType x =
  modify $ \st -> st{ mClasses = updateMap (mUpdateDomainType x) $ mClasses st }

mUpdateDomainType :: (String,DomainType) -> LClass -> Maybe LClass
mUpdateDomainType (n,dt1) = \c -> case Map.lookup n $ domains c of
  Nothing -> Nothing
  Just dt2 -> Just $ c{ domains = Map.insert n (unifyDomainTypes dt1 dt2) $ domains c }

inferClasses :: Map String LClass -> Map String LClass
inferClasses cls = Map.map (\ps -> initLClass{ ports = ps }) tbl
  where
  tbl = foldr addToTable Map.empty $ nub $ sort $ concatMap (inferPorts ns) xs
  (ns,xs) = unzip $ Map.toList cls

inferPorts :: [String] -> LClass -> [(String,String)]
inferPorts ss cl = concatMap f $ connections cl
  where
  f (a,b,c,d) = catMaybes [ g a b, g c d ]
  g a b = case Map.lookup a $ domains cl of
    Nothing -> Nothing
    Just (s,_) -> if s `elem` ss then Nothing else Just (s,b)

addToTable :: (Ord a, Show a, Eq b) => (a,b) -> Map a [b] -> Map a [b]
addToTable (a,b) tbl = case Map.lookup a tbl of
  Nothing -> Map.insert a [b] tbl
  Just xs -> Map.insert a (ins b xs) tbl

updateMap :: Ord k => (a -> Maybe a) -> Map k a -> Map k a
updateMap f m = Map.fromList $ zip a $ updateList f b
  where (a,b) = unzip $ Map.toList m

updateList :: (a -> Maybe a) -> [a] -> [a]
updateList _ [] = []
updateList f (x:xs) = case f x of
  Just x1 -> x1 : xs
  Nothing -> x : updateList f xs

initLClass :: LClass
initLClass = LClass [] Map.empty []

unifyDomainTypes :: DomainType -> DomainType -> DomainType
unifyDomainTypes x1 x2 = case (x1,x2) of
  (_, ("unknown",_)) -> x1
  (("unknown",_), _) -> x2
  ((a, bs1), (_, bs2)) -> (a, nub $ sort $ bs1 ++ bs2)

domainTypesAllow :: (String,Allow) -> [(String,DomainType)]
domainTypesAllow (_,(a,b,c,_)) =
  [ (stripDollar a,userDT "process")
  , (stripDollar b,userDT c)
  ]

domainTypeFC :: (String,String) -> (String,DomainType)
domainTypeFC (a,b) = (a,("file",[b]))

-- lobster pretty-printing

ppLModule :: LModule -> Doc
ppLModule m =
  vcat $ [ ppLClass n x | (n,x) <- Map.toList $ mClasses m ] ++ [ppDomains $ mDomains m]

ppLClass :: String -> LClass -> Doc
ppLClass n x = vcat
  [ text "class" <+> text (capitalize n) <> text "()" <+> text "{"
  , nest 2 $ vcat $ body
  , text "}"
  ]
  where
  body = map ppPort (ports x) ++ [ppDomains $ domains x] ++ map ppConnection (connections x)

ppDomains :: Map String DomainType -> Doc
ppDomains m = vcat [ ppDomain a b | (a,b) <- Map.toList m ]

ppPort :: String -> Doc
ppPort x = text "port" <+> text x <> text ";"

ppDomain :: String -> DomainType -> Doc
ppDomain n a = text "domain" <+> text n <+> text "=" <+> ppDomainType a

ppDomainType :: DomainType -> Doc
ppDomainType (a,bs) = text (capitalize a) <> text "(" <> args <> text ");"
  where
  args = text $ concat $ intersperse "," $ map show bs    

ppConnection :: Connection -> Doc
ppConnection (a,b,c,d) = f a b <+> text "--" <+> f c d <> text ";"
  where f x y = text x <> (if null y then empty else text "." <> text y)

-- main helper functions

checkOpt_ :: [String] -> IO (Options,FilePath)
checkOpt_ args = do
  (opts,fns) <- checkOpt options defaultOptions args
  case fns of
    [a] -> do
      x <- canonicalizePath a
      return (opts, x)
    _ -> do
      pn <- getProgName
      exitErrors ["expecting: " ++ pn ++ " <input directory>"]

checkOpt :: [OptDescr (a -> a)] -> a -> [String] -> IO (a,[String])
checkOpt os d args =
  case getOpt Permute os args of
    (f, r, [])   -> return (foldl (flip id) d f, r)
    (_, _, errs) -> exitErrors errs

reportErrors :: [String] -> IO ()
reportErrors errs = do
  p <- getProgName
  putStrLn (p ++ ":" ++ concat errs)

exitErrors :: [String] -> IO a
exitErrors errs = do
  reportErrors errs
  printUsage
  exitFailure

-- misc. functions

warnPat :: Monad m => String -> String -> m ()
warnPat loc s = warn (loc ++ ":unhandled pattern:" ++ s)

warn :: Monad m => String -> m ()
warn s = trace ("warning:" ++ s) $ return ()

ins :: (Eq a) => a -> [a] -> [a]
ins x xs
  | x `elem` xs = xs
  | otherwise   = xs ++ [x]

capitalize :: String -> String
capitalize "" = ""
capitalize (x:xs) = toUpper x : xs

stripDollar :: String -> String
stripDollar ('$':cs) = dropWhile (not . isAlpha) cs
--stripDollar s = s
stripDollar (c : cs) = c : stripDollar cs
stripDollar [] = []

substDollar :: String -> String -> String
substDollar a ('$':cs) = a ++ dropWhile ((/=) '_') cs
substDollar a (c : cs) = c : substDollar a cs
substDollar _ [] = []
--substDollar _ s = s
