{-# LANGUAGE LambdaCase #-}
module Data.GI.CodeGen.Callable
    ( genCallable

    , hOutType
    , arrayLengths
    , arrayLengthsMap
    , callableSignature
    , fixupCallerAllocates

    , wrapMaybe
    , inArgInterfaces
    ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif
import Control.Monad (forM, forM_, when)
import Data.Bool (bool)
import Data.List (nub, (\\))
import Data.Maybe (isJust)
import Data.Monoid ((<>))
import Data.Tuple (swap)
import Data.Typeable (TypeRep, typeOf)
import qualified Data.Map as Map
import qualified Data.Text as T
import Data.Text (Text)

import Data.GI.CodeGen.API
import Data.GI.CodeGen.Code
import Data.GI.CodeGen.Conversions
import Data.GI.CodeGen.SymbolNaming
import Data.GI.CodeGen.Transfer
import Data.GI.CodeGen.Type
import Data.GI.CodeGen.Util

import Text.Show.Pretty (ppShow)

hOutType :: Callable -> [Arg] -> Bool -> ExcCodeGen TypeRep
hOutType callable outArgs ignoreReturn = do
  hReturnType <- case returnType callable of
                   Nothing -> return $ typeOf ()
                   Just r -> if ignoreReturn
                             then return $ typeOf ()
                             else haskellType r
  hOutArgTypes <- forM outArgs $ \outarg ->
                  wrapMaybe outarg >>= bool
                                (haskellType (argType outarg))
                                (maybeT <$> haskellType (argType outarg))
  nullableReturnType <- maybe (return False) typeIsNullable (returnType callable)
  let maybeHReturnType = if returnMayBeNull callable && not ignoreReturn
                            && nullableReturnType
                         then maybeT hReturnType
                         else hReturnType
  return $ case (outArgs, tshow maybeHReturnType) of
             ([], _)   -> maybeHReturnType
             (_, "()") -> "(,)" `con` hOutArgTypes
             _         -> "(,)" `con` (maybeHReturnType : hOutArgTypes)

mkForeignImport :: Text -> Callable -> Bool -> CodeGen ()
mkForeignImport symbol callable throwsGError = do
    line first
    indent $ do
        mapM_ (\a -> line =<< fArgStr a) (args callable)
        when throwsGError $
               line $ padTo 40 "Ptr (Ptr GError) -> " <> "-- error"
        line =<< last
    where
    first = "foreign import ccall \"" <> symbol <> "\" " <>
                symbol <> " :: "
    fArgStr arg = do
        ft <- foreignType $ argType arg
        weAlloc <- isJust <$> requiresAlloc (argType arg)
        let ft' = if direction arg == DirectionIn || weAlloc
                     || argCallerAllocates arg
                  then
                      ft
                  else
                      ptr ft
        let start = tshow ft' <> " -> "
        return $ padTo 40 start <> "-- " <> (argCName arg)
                   <> " : " <> tshow (argType arg)
    last = tshow <$> io <$> case returnType callable of
                             Nothing -> return $ typeOf ()
                             Just r  -> foreignType r

-- | Given an argument to a function, return whether it should be
-- wrapped in a maybe type (useful for nullable types). We do some
-- sanity checking to make sure that the argument is actually nullable
-- (a relatively common annotation mistake is to mix up (optional)
-- with (nullable)).
wrapMaybe :: Arg -> CodeGen Bool
wrapMaybe arg = if mayBeNull arg
                then typeIsNullable (argType arg)
                else return False

-- Given the list of arguments returns the list of constraints and the
-- list of types in the signature.
inArgInterfaces :: [Arg] -> ExcCodeGen ([Text], [Text])
inArgInterfaces inArgs = consAndTypes (['a'..'z'] \\ ['m']) inArgs
  where
    consAndTypes :: [Char] -> [Arg] -> ExcCodeGen ([Text], [Text])
    consAndTypes _ [] = return ([], [])
    consAndTypes letters (arg:args) = do
      (ls, t, cons) <- argumentType letters $ argType arg
      t' <- wrapMaybe arg >>= bool (return t)
                                   (return $ "Maybe (" <> t <> ")")
      (restCons, restTypes) <- consAndTypes ls args
      return (cons <> restCons, t' : restTypes)

-- Given a callable, return a list of (array, length) pairs, where in
-- each pair "length" is the argument holding the length of the
-- (non-zero-terminated, non-fixed size) C array.
arrayLengthsMap :: Callable -> [(Arg, Arg)] -- List of (array, length)
arrayLengthsMap callable = go (args callable) []
    where
      go :: [Arg] -> [(Arg, Arg)] -> [(Arg, Arg)]
      go [] acc = acc
      go (a:as) acc = case argType a of
                        TCArray False fixedSize length _ ->
                            if fixedSize > -1 || length == -1
                            then go as acc
                            else go as $ (a, (args callable)!!length) : acc
                        _ -> go as acc

-- Return the list of arguments of the callable that contain length
-- arguments, including a possible length for the result of calling
-- the function.
arrayLengths :: Callable -> [Arg]
arrayLengths callable = map snd (arrayLengthsMap callable) <>
               -- Often one of the arguments is just the length of
               -- the result.
               case returnType callable of
                 Just (TCArray False (-1) length _) ->
                     if length > -1
                     then [(args callable)!!length]
                     else []
                 _ -> []

-- This goes through a list of [(a,b)], and tags every entry where the
-- "b" field has occurred before with the value of "a" for which it
-- occurred. (The first appearance is not tagged.)
classifyDuplicates :: Ord b => [(a, b)] -> [(a, b, Maybe a)]
classifyDuplicates args = doClassify Map.empty args
    where doClassify :: Ord b => Map.Map b a -> [(a, b)] -> [(a, b, Maybe a)]
          doClassify _ [] = []
          doClassify found ((value, key):args) =
              (value, key, Map.lookup key found) :
                doClassify (Map.insert key value found) args

-- Read the length of in array arguments from the corresponding
-- Haskell objects. A subtlety is that sometimes a single length
-- argument is expected from the C side to encode the length of
-- various lists. Ideally we would encode this in the types, but the
-- resulting API would be rather cumbersome. We insted perform runtime
-- checks to make sure that the given lists have the same length.
readInArrayLengths :: Name -> Callable -> [Arg] -> ExcCodeGen ()
readInArrayLengths name callable hInArgs = do
  let lengthMaps = classifyDuplicates $ arrayLengthsMap callable
  forM_ lengthMaps $ \(array, length, duplicate) ->
      when (array `elem` hInArgs) $
        case duplicate of
        Nothing -> readInArrayLength array length
        Just previous -> checkInArrayLength name array length previous

-- Read the length of an array into the corresponding variable.
readInArrayLength :: Arg -> Arg -> ExcCodeGen ()
readInArrayLength array length = do
  let lvar = escapedArgName length
      avar = escapedArgName array
  wrapMaybe array >>= bool
                (do
                  al <- computeArrayLength avar (argType array)
                  line $ "let " <> lvar <> " = " <> al)
                (do
                  line $ "let " <> lvar <> " = case " <> avar <> " of"
                  indent $ indent $ do
                    line $ "Nothing -> 0"
                    let jarray = "j" <> ucFirst avar
                    al <- computeArrayLength jarray (argType array)
                    line $ "Just " <> jarray <> " -> " <> al)

-- Check that the given array has a length equal to the given length
-- variable.
checkInArrayLength :: Name -> Arg -> Arg -> Arg -> ExcCodeGen ()
checkInArrayLength n array length previous = do
  let name = lowerName n
      funcName = namespace n <> "." <> name
      lvar = escapedArgName length
      avar = escapedArgName array
      expectedLength = avar <> "_expected_length_"
      pvar = escapedArgName previous
  wrapMaybe array >>= bool
            (do
              al <- computeArrayLength avar (argType array)
              line $ "let " <> expectedLength <> " = " <> al)
            (do
              line $ "let " <> expectedLength <> " = case " <> avar <> " of"
              indent $ indent $ do
                line $ "Nothing -> 0"
                let jarray = "j" <> ucFirst avar
                al <- computeArrayLength jarray (argType array)
                line $ "Just " <> jarray <> " -> " <> al)
  line $ "when (" <> expectedLength <> " /= " <> lvar <> ") $"
  indent $ line $ "error \"" <> funcName <> " : length of '" <> avar <>
             "' does not agree with that of '" <> pvar <> "'.\""

-- Whether to skip the return value in the generated bindings. The
-- C convention is that functions throwing an error and returning
-- a gboolean set the boolean to TRUE iff there is no error, so
-- the information is always implicit in whether we emit an
-- exception or not, so the return value can be omitted from the
-- generated bindings without loss of information (and omitting it
-- gives rise to a nicer API). See
-- https://bugzilla.gnome.org/show_bug.cgi?id=649657
skipRetVal :: Callable -> Bool -> Bool
skipRetVal callable throwsGError =
    (skipReturn callable) ||
         (throwsGError && returnType callable == Just (TBasicType TBoolean))

freeInArgs' :: (Arg -> Text -> Text -> ExcCodeGen [Text]) ->
               Callable -> Map.Map Text Text -> ExcCodeGen [Text]
freeInArgs' freeFn callable nameMap = concat <$> actions
    where
      actions :: ExcCodeGen [[Text]]
      actions = forM (args callable) $ \arg ->
        case Map.lookup (escapedArgName arg) nameMap of
          Just name -> freeFn arg name $
                       -- Pass in the length argument in case it's needed.
                       case argType arg of
                         TCArray False (-1) (-1) _ -> undefined
                         TCArray False (-1) length _ ->
                             escapedArgName $ (args callable)!!length
                         _ -> undefined
          Nothing -> badIntroError $ "freeInArgs: do not understand " <> tshow arg

-- Return the list of actions freeing the memory associated with the
-- callable variables. This is run if the call to the C function
-- succeeds, if there is an error freeInArgsOnError below is called
-- instead.
freeInArgs = freeInArgs' freeInArg

-- Return the list of actions freeing the memory associated with the
-- callable variables. This is run in case there is an error during
-- the call.
freeInArgsOnError = freeInArgs' freeInArgOnError

-- Marshall the haskell arguments into their corresponding C
-- equivalents. omitted gives a list of DirectionIn arguments that
-- should be ignored, as they will be dealt with separately.
prepareArgForCall :: [Arg] -> Arg -> ExcCodeGen Text
prepareArgForCall omitted arg = do
  isCallback <- findAPI (argType arg) >>=
                \case Just (APICallback _) -> return True
                      _ -> return False
  when (isCallback && direction arg /= DirectionIn) $
       notImplementedError "Only callbacks with DirectionIn are supported"

  case direction arg of
    DirectionIn -> if arg `elem` omitted
                   then return . escapedArgName $ arg
                   else if isCallback
                        then prepareInCallback arg
                        else prepareInArg arg
    DirectionInout -> prepareInoutArg arg
    DirectionOut -> prepareOutArg arg

prepareInArg :: Arg -> ExcCodeGen Text
prepareInArg arg = do
  let name = escapedArgName arg
  wrapMaybe arg >>= bool
            (convert name $ hToF (argType arg) (transfer arg))
            (do
              let maybeName = "maybe" <> ucFirst name
              line $ maybeName <> " <- case " <> name <> " of"
              indent $ do
                line $ "Nothing -> return nullPtr"
                let jName = "j" <> ucFirst name
                line $ "Just " <> jName <> " -> do"
                indent $ do
                         converted <- convert jName $ hToF (argType arg)
                                                           (transfer arg)
                         line $ "return " <> converted
                return maybeName)

-- Callbacks are a fairly special case, we treat them separately.
prepareInCallback :: Arg -> CodeGen Text
prepareInCallback arg = do
  let name = escapedArgName arg
      ptrName = "ptr" <> name
      scope = argScope arg

  (maker, wrapper) <- case argType arg of
                        TInterface ns n ->
                            do
                              let tn = Name ns n
                              maker <- qualifiedSymbol ("mk" <> n) tn
                              wrapper <- qualifiedSymbol (lcFirst n <> "Wrapper") tn
                              return $ (maker, wrapper)
                        _ -> terror $ "prepareInCallback : Not an interface! " <> T.pack (ppShow arg)

  when (scope == ScopeTypeAsync) $ do
   ft <- tshow <$> foreignType (argType arg)
   line $ ptrName <> " <- callocMem :: IO (Ptr (" <> ft <> "))"

  wrapMaybe arg >>= bool
            (do
              let name' = prime name
                  p = if (scope == ScopeTypeAsync)
                      then parenthesize $ "Just " <> ptrName
                      else "Nothing"
              line $ name' <> " <- " <> maker <> " "
                       <> parenthesize (wrapper <> " " <> p <> " " <> name)
              when (scope == ScopeTypeAsync) $
                   line $ "poke " <> ptrName <> " " <> name'
              return name')
            (do
              let maybeName = "maybe" <> ucFirst name
              line $ maybeName <> " <- case " <> name <> " of"
              indent $ do
                line $ "Nothing -> return (castPtrToFunPtr nullPtr)"
                let jName = "j" <> ucFirst name
                    jName' = prime jName
                line $ "Just " <> jName <> " -> do"
                indent $ do
                         let p = if (scope == ScopeTypeAsync)
                                 then parenthesize $ "Just " <> ptrName
                                 else "Nothing"
                         line $ jName' <> " <- " <> maker <> " "
                                  <> parenthesize (wrapper <> " "
                                                   <> p <> " " <> jName)
                         when (scope == ScopeTypeAsync) $
                              line $ "poke " <> ptrName <> " " <> jName'
                         line $ "return " <> jName'
              return maybeName)

prepareInoutArg :: Arg -> ExcCodeGen Text
prepareInoutArg arg = do
  name' <- prepareInArg arg
  ft <- foreignType $ argType arg
  allocInfo <- requiresAlloc (argType arg)
  case allocInfo of
    Just (isBoxed, n) -> do
         let allocator = if isBoxed
                         then "callocBoxedBytes"
                         else "callocBytes"
         wrapMaybe arg >>= bool
            (do
              name'' <- genConversion (prime name') $
                        literal $ M $ allocator <> " " <> tshow n <>
                                    " :: " <> tshow (io ft)
              line $ "memcpy " <> name'' <> " " <> name' <> " " <> tshow n
              return name'')
             -- The semantics of this case are somewhat undefined.
            (notImplementedError "Nullable inout structs not supported")
    Nothing -> do
      if argCallerAllocates arg
      then return name'
      else do
        name'' <- genConversion (prime name') $
                  literal $ M $ "allocMem :: " <> tshow (io $ ptr ft)
        line $ "poke " <> name'' <> " " <> name'
        return name''

prepareOutArg :: Arg -> CodeGen Text
prepareOutArg arg = do
  let name = escapedArgName arg
  ft <- foreignType $ argType arg
  allocInfo <- requiresAlloc (argType arg)
  case allocInfo of
    Just (isBoxed, n) -> do
        let allocator = if isBoxed
                        then "callocBoxedBytes"
                        else "callocBytes"
        genConversion name $ literal $ M $ allocator <> " " <> tshow n <>
                                      " :: " <> tshow (io ft)
    Nothing ->
        genConversion name $
                  literal $ M $ "allocMem :: " <> tshow (io $ ptr ft)

-- Convert a non-zero terminated out array, stored in a variable
-- named "aname", into the corresponding Haskell object.
convertOutCArray :: Callable -> Type -> Text -> Map.Map Text Text ->
                    Transfer -> (Text -> Text) -> ExcCodeGen Text
convertOutCArray callable t@(TCArray False fixed length _) aname
                 nameMap transfer primeLength = do
  if fixed > -1
  then do
    unpacked <- convert aname $ unpackCArray (tshow fixed) t transfer
    -- Free the memory associated with the array
    freeContainerType transfer t aname undefined
    return unpacked
  else do
    when (length == -1) $
         badIntroError $ "Unknown length for \"" <> aname <> "\""
    let lname = escapedArgName $ (args callable)!!length
    lname' <- case Map.lookup lname nameMap of
                Just n -> return n
                Nothing ->
                    badIntroError $ "Couldn't find out array length " <>
                                            lname
    let lname'' = primeLength lname'
    unpacked <- convert aname $ unpackCArray lname'' t transfer
    -- Free the memory associated with the array
    freeContainerType transfer t aname lname''
    return unpacked

-- Remove the warning, this should never be reached.
convertOutCArray _ t _ _ _ _ =
    terror $ "convertOutCArray : unexpected " <> tshow t

-- Read the array lengths for out arguments.
readOutArrayLengths :: Callable -> Map.Map Text Text -> ExcCodeGen ()
readOutArrayLengths callable nameMap = do
  let lNames = nub $ map escapedArgName $
               filter ((/= DirectionIn) . direction) $
               arrayLengths callable
  forM_ lNames $ \lname -> do
    lname' <- case Map.lookup lname nameMap of
                   Just n -> return n
                   Nothing ->
                       badIntroError $ "Couldn't find out array length " <>
                                               lname
    genConversion lname' $ apply $ M "peek"

-- Touch DirectionIn arguments so we are sure that they exist when the
-- C function was called.
touchInArg :: Arg -> ExcCodeGen ()
touchInArg arg = when (direction arg /= DirectionOut) $ do
  let name = escapedArgName arg
  case elementType (argType arg) of
    Just a -> do
      managed <- isManaged a
      when managed $ wrapMaybe arg >>= bool
              (line $ "mapM_ touchManagedPtr " <> name)
              (line $ "whenJust " <> name <> " (mapM_ touchManagedPtr)")
    Nothing -> do
      managed <- isManaged (argType arg)
      when managed $ wrapMaybe arg >>= bool
           (line $ "touchManagedPtr " <> name)
           (line $ "whenJust " <> name <> " touchManagedPtr")

-- Find the association between closure arguments and their
-- corresponding callback.
closureToCallbackMap :: Callable -> ExcCodeGen (Map.Map Int Arg)
closureToCallbackMap callable =
    -- The introspection info does not specify the closure for destroy
    -- notify's associated with a callback, since it is implicitly the
    -- same one as the ScopeTypeNotify callback associated with the
    -- DestroyNotify.
    go (filter (not . (`elem` destroyers)) $ args callable) Map.empty

    where destroyers = map (args callable!!) . filter (/= -1) . map argDestroy
                       $ args callable

          go :: [Arg] -> Map.Map Int Arg -> ExcCodeGen (Map.Map Int Arg)
          go [] m = return m
          go (arg:as) m =
              if argScope arg == ScopeTypeInvalid
              then go as m
              else case argClosure arg of
                  (-1) -> go as m
                  c -> case Map.lookup c m of
                      Just _ -> notImplementedError $
                                "Closure for multiple callbacks unsupported"
                                <> T.pack (ppShow arg) <> "\n"
                                <> T.pack (ppShow callable)
                      Nothing -> go as $ Map.insert c arg m

-- user_data style arguments.
prepareClosures :: Callable -> Map.Map Text Text -> ExcCodeGen ()
prepareClosures callable nameMap = do
  m <- closureToCallbackMap callable
  let closures = filter (/= -1) . map argClosure $ args callable
  forM_ closures $ \closure ->
      case Map.lookup closure m of
        Nothing -> badIntroError $ "Closure not found! "
                                <> T.pack (ppShow callable)
                                <> "\n" <> T.pack (ppShow m)
                                <> "\n" <> tshow closure
        Just cb -> do
          let closureName = escapedArgName $ (args callable)!!closure
              n = escapedArgName cb
          n' <- case Map.lookup n nameMap of
                  Just n -> return n
                  Nothing -> badIntroError $ "Cannot find closure name!! "
                                           <> T.pack (ppShow callable) <> "\n"
                                           <> T.pack (ppShow nameMap)
          case argScope cb of
            ScopeTypeInvalid -> badIntroError $ "Invalid scope! "
                                              <> T.pack (ppShow callable)
            ScopeTypeNotified -> do
                line $ "let " <> closureName <> " = castFunPtrToPtr " <> n'
                case argDestroy cb of
                  (-1) -> badIntroError $
                          "ScopeTypeNotified without destructor! "
                           <> T.pack (ppShow callable)
                  k -> let destroyName =
                            escapedArgName $ (args callable)!!k in
                       line $ "let " <> destroyName <> " = safeFreeFunPtrPtr"
            ScopeTypeAsync ->
                line $ "let " <> closureName <> " = nullPtr"
            ScopeTypeCall -> line $ "let " <> closureName <> " = nullPtr"

freeCallCallbacks :: Callable -> Map.Map Text Text -> ExcCodeGen ()
freeCallCallbacks callable nameMap =
    forM_ (args callable) $ \arg -> do
       let name = escapedArgName arg
       name' <- case Map.lookup name nameMap of
                  Just n -> return n
                  Nothing -> badIntroError $ "Could not find " <> name
                                <> " in " <> T.pack (ppShow callable) <> "\n"
                                <> T.pack (ppShow nameMap)
       when (argScope arg == ScopeTypeCall) $
            line $ "safeFreeFunPtr $ castFunPtrToPtr " <> name'

formatHSignature :: Callable -> Bool -> ExcCodeGen ()
formatHSignature callable throwsGError = do
  (constraints, vars) <- callableSignature callable throwsGError
  indent $ do
      line $ "(" <> T.intercalate ", " constraints <> ") =>"
      forM_ (zip ("" : repeat "-> ") vars) $ \(prefix, (t, name)) ->
           line $ withComment (prefix <> t) name

-- | The Haskell signature for the given callable. It returns a tuple
-- ([constraints], [(type, argname)]).
callableSignature :: Callable -> Bool -> ExcCodeGen ([Text], [(Text, Text)])
callableSignature callable throwsGError = do
  let (hInArgs, _) = callableHInArgs callable
  (argConstraints, types) <- inArgInterfaces hInArgs
  let constraints = ("MonadIO m" : argConstraints)
      ignoreReturn = skipRetVal callable throwsGError
  outType <- hOutType callable (callableHOutArgs callable) ignoreReturn
  let allNames = map escapedArgName hInArgs ++ ["result"]
      allTypes = types ++ [tshow ("m" `con` [outType])]
  return (constraints, zip allTypes allNames)

-- | "In" arguments for the given callable on the Haskell side,
-- together with the omitted arguments.
callableHInArgs :: Callable -> ([Arg], [Arg])
callableHInArgs callable =
    let inArgs = filter ((/= DirectionOut) . direction) $ args callable
                 -- We do not expose user_data arguments,
                 -- destroynotify arguments, and C array length
                 -- arguments to Haskell code.
        closures = map (args callable!!) . filter (/= -1) . map argClosure $ inArgs
        destroyers = map (args callable!!) . filter (/= -1) . map argDestroy $ inArgs
        omitted = arrayLengths callable <> closures <> destroyers
    in (filter (`notElem` omitted) inArgs, omitted)

-- | "Out" arguments for the given callable on the Haskell side.
callableHOutArgs :: Callable -> [Arg]
callableHOutArgs callable =
    let outArgs = filter ((/= DirectionIn) . direction) $ args callable
    in filter (`notElem` (arrayLengths callable)) outArgs

-- | Convert the result of the foreign call to Haskell.
convertResult :: Callable -> Text -> Bool -> Map.Map Text Text ->
                 ExcCodeGen Text
convertResult callable symbol ignoreReturn nameMap =
    if ignoreReturn || returnType callable == Nothing
    then return (error "convertResult: unreachable code reached, bug!")
    else do
      nullableReturnType <- maybe (return False) typeIsNullable (returnType callable)
      if returnMayBeNull callable && nullableReturnType
      then do
        line $ "maybeResult <- convertIfNonNull result $ \\result' -> do"
        indent $ do
             converted <- unwrappedConvertResult "result'"
             line $ "return " <> converted
             return "maybeResult"
      else do
        when nullableReturnType $
             line $ "checkUnexpectedReturnNULL \"" <> symbol
                      <> "\" result"
        unwrappedConvertResult "result"

    where
      unwrappedConvertResult rname =
          case returnType callable of
            -- Arrays without length information are just passed
            -- along.
            Just (TCArray False (-1) (-1) _) -> return rname
            -- Not zero-terminated C arrays require knowledge of the
            -- length, so we deal with them directly.
            Just (t@(TCArray False _ _ _)) ->
                convertOutCArray callable t rname nameMap
                                 (returnTransfer callable) prime
            Just t -> do
                result <- convert rname $ fToH t (returnTransfer callable)
                freeContainerType (returnTransfer callable) t rname undefined
                return result
            Nothing -> return (error "unwrappedConvertResult: bug!")

-- | Marshal a foreign out argument to Haskell, returning the name of
-- the variable containing the converted Haskell value.
convertOutArg :: Callable -> Map.Map Text Text -> Arg -> ExcCodeGen Text
convertOutArg callable nameMap arg = do
  let name = escapedArgName arg
  inName <- case Map.lookup name nameMap of
      Just name' -> return name'
      Nothing -> badIntroError $ "Parameter " <> name <> " not found!"
  case argType arg of
      -- Passed along as a raw pointer
      TCArray False (-1) (-1) _ ->
          if argCallerAllocates arg
          then return inName
          else genConversion inName $ apply $ M "peek"
      t@(TCArray False _ _ _) -> do
          aname' <- if argCallerAllocates arg
                    then return inName
                    else genConversion inName $ apply $ M "peek"
          let arrayLength = if argCallerAllocates arg
                            then id
                            else prime
              wrapArray a = convertOutCArray callable t a
                                nameMap (transfer arg) arrayLength
          wrapMaybe arg >>= bool
                 (wrapArray aname')
                 (do line $ "maybe" <> ucFirst aname'
                         <> " <- convertIfNonNull " <> aname'
                         <> " $ \\" <> prime aname' <> " -> do"
                     indent $ do
                         wrapped <- wrapArray (prime aname')
                         line $ "return " <> wrapped
                     return $ "maybe" <> ucFirst aname')
      t -> do
          weAlloc <- isJust <$> requiresAlloc t
          peeked <- if weAlloc || argCallerAllocates arg
                   then return inName
                   else genConversion inName $ apply $ M "peek"
          -- If we alloc we always take control of the resulting
          -- memory, otherwise we may leak.
          let transfer' = if weAlloc || argCallerAllocates arg
                         then TransferEverything
                         else transfer arg
          result <- do
              let wrap ptr = convert ptr $ fToH (argType arg) transfer'
              wrapMaybe arg >>= bool
                  (wrap peeked)
                  (do line $ "maybe" <> ucFirst peeked
                          <> " <- convertIfNonNull " <> peeked
                          <> " $ \\" <> prime peeked <> " -> do"
                      indent $ do
                          wrapped <- wrap (prime peeked)
                          line $ "return " <> wrapped
                      return $ "maybe" <> ucFirst peeked)
          -- Free the memory associated with the out argument
          freeContainerType transfer' t peeked undefined
          return result

-- | Convert the list of out arguments to Haskell, returning the
-- names of the corresponding variables containing the marshaled values.
convertOutArgs :: Callable -> Map.Map Text Text -> [Arg] -> ExcCodeGen [Text]
convertOutArgs callable nameMap hOutArgs =
    forM hOutArgs (convertOutArg callable nameMap)

-- | Invoke the given C function, taking care of errors.
invokeCFunction :: Callable -> Text -> Bool -> Bool -> [Text] -> CodeGen ()
invokeCFunction callable symbol throwsGError ignoreReturn argNames = do
  let returnBind = case returnType callable of
                     Nothing -> ""
                     _       -> if ignoreReturn
                                then "_ <- "
                                else "result <- "
      maybeCatchGErrors = if throwsGError
                          then "propagateGError $ "
                          else ""
  line $ returnBind <> maybeCatchGErrors
           <> symbol <> (T.concat . map (" " <>)) argNames

-- | Return the result of the call, possibly including out arguments.
returnResult :: Callable -> Bool -> Text -> [Text] -> CodeGen ()
returnResult callable ignoreReturn result pps =
    if ignoreReturn || returnType callable == Nothing
    then case pps of
        []      -> line "return ()"
        (pp:[]) -> line $ "return " <> pp
        _       -> line $ "return (" <> T.intercalate ", " pps <> ")"
    else case pps of
        [] -> line $ "return " <> result
        _  -> line $ "return (" <> T.intercalate ", " (result : pps) <> ")"

-- | Generate a Haskell wrapper for the given foreign function.
genHaskellWrapper :: Name -> Text -> Callable -> Bool -> ExcCodeGen ()
genHaskellWrapper n symbol callable throwsGError = group $ do
    let name = lowerName n
        (hInArgs, omitted) = callableHInArgs callable
        hOutArgs = callableHOutArgs callable
        ignoreReturn = skipRetVal callable throwsGError

    line $ name <> " ::"
    formatHSignature callable ignoreReturn
    line $ name <> " " <> T.intercalate " " (map escapedArgName hInArgs) <> " = liftIO $ do"
    indent (genWrapperBody n symbol callable throwsGError
                           ignoreReturn hInArgs hOutArgs omitted)

-- | Generate the body of the Haskell wrapper for the given foreign symbol.
genWrapperBody :: Name -> Text -> Callable -> Bool ->
                  Bool -> [Arg] -> [Arg] -> [Arg] ->
                  ExcCodeGen ()
genWrapperBody n symbol callable throwsGError
               ignoreReturn hInArgs hOutArgs omitted = do
    readInArrayLengths n callable hInArgs
    inArgNames <- forM (args callable) $ \arg ->
                  prepareArgForCall omitted arg
    -- Map from argument names to names passed to the C function
    let nameMap = Map.fromList $ flip zip inArgNames
                               $ map escapedArgName $ args callable
    prepareClosures callable nameMap
    if throwsGError
    then do
        line "onException (do"
        indent $ do
            invokeCFunction callable symbol throwsGError
                            ignoreReturn inArgNames
            readOutArrayLengths callable nameMap
            result <- convertResult callable symbol ignoreReturn nameMap
            pps <- convertOutArgs callable nameMap hOutArgs
            freeCallCallbacks callable nameMap
            forM_ (args callable) touchInArg
            mapM_ line =<< freeInArgs callable nameMap
            returnResult callable ignoreReturn result pps
        line " ) (do"
        indent $ do
            freeCallCallbacks callable nameMap
            actions <- freeInArgsOnError callable nameMap
            case actions of
                [] -> line $ "return ()"
                _ -> mapM_ line actions
        line " )"
    else do
        invokeCFunction callable symbol throwsGError
                        ignoreReturn inArgNames
        readOutArrayLengths callable nameMap
        result <- convertResult callable symbol ignoreReturn nameMap
        pps <- convertOutArgs callable nameMap hOutArgs
        freeCallCallbacks callable nameMap
        forM_ (args callable) touchInArg
        mapM_ line =<< freeInArgs callable nameMap
        returnResult callable ignoreReturn result pps

-- | caller-allocates arguments are arguments that the caller
-- allocates, and the called function modifies. They are marked as
-- 'out' argumens in the introspection data, we treat them as 'inout'
-- arguments instead. The semantics are somewhat tricky: for memory
-- management purposes they should be treated as "in" arguments, but
-- from the point of view of the exposed API they should be treated as
-- "inout". Unfortunately we cannot always just assume that they are
-- purely "out", so in many cases the generated API is somewhat
-- suboptimal (since the initial values are not important): for
-- example for g_io_channel_read_chars the size of the buffer to read
-- is determined by the caller-allocates argument. As a compromise, we
-- assume that we can allocate anything that is not a TCArray.
fixupCallerAllocates :: Callable -> Callable
fixupCallerAllocates c =
    c{args = map (fixupLength . fixupArg . normalize) (args c)}
    where fixupArg :: Arg -> Arg
          fixupArg a = if argCallerAllocates a
                       then a {direction = DirectionInout}
                       else a

          lengthsMap :: Map.Map Arg Arg
          lengthsMap = Map.fromList (map swap (arrayLengthsMap c))

          -- Length arguments of caller-allocates arguments should be
          -- treated as "in".
          fixupLength :: Arg -> Arg
          fixupLength a = case Map.lookup a lengthsMap of
                            Nothing -> a
                            Just array ->
                                if argCallerAllocates array
                                then a {direction = DirectionIn}
                                else a

          -- We impose that out or inout arguments of non-array type
          -- are never caller-allocates.
          normalize :: Arg -> Arg
          normalize (a@Arg{argType = TCArray _ _ _ _}) = a
          normalize a = a {argCallerAllocates = False}

genCallable :: Name -> Text -> Callable -> Bool -> ExcCodeGen ()
genCallable n symbol callable throwsGError = do
    group $ do
        line $ "-- Args : " <> (tshow $ args callable)
        line $ "-- Lengths : " <> (tshow $ arrayLengths callable)
        line $ "-- returnType : " <> (tshow $ returnType callable)
        line $ "-- throws : " <> (tshow throwsGError)
        line $ "-- Skip return : " <> (tshow $ skipReturn callable)
        when (skipReturn callable && returnType callable /= Just (TBasicType TBoolean)) $
             do line "-- XXX return value ignored, but it is not a boolean."
                line "--     This may be a memory leak?"

    let callable' = fixupCallerAllocates callable

    mkForeignImport symbol callable' throwsGError

    blank

    line $ deprecatedPragma (lowerName n) (callableDeprecated callable)
    exportMethod (lowerName n) (lowerName n)
    genHaskellWrapper n symbol callable' throwsGError
