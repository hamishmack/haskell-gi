module Data.GI.CodeGen.Properties
    ( genInterfaceProperties
    , genObjectProperties
    , genNamespacedPropLabels
    ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif
import Control.Monad (forM_, when, unless)
import Data.Monoid ((<>))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Set as S

import Foreign.C.Types (CInt, CUInt)
import Foreign.Storable (sizeOf)

import Data.GI.CodeGen.API
import Data.GI.CodeGen.Conversions
import Data.GI.CodeGen.Code
import Data.GI.CodeGen.GObject
import Data.GI.CodeGen.Inheritance (fullObjectPropertyList, fullInterfacePropertyList)
import Data.GI.CodeGen.SymbolNaming (lowerName, upperName, classConstraint,
                                     hyphensToCamelCase, qualifiedSymbol)
import Data.GI.CodeGen.Type
import Data.GI.CodeGen.Util

propTypeStr :: Type -> CodeGen Text
propTypeStr t = case t of
   TBasicType TUTF8 -> return "String"
   TBasicType TFileName -> return "String"
   TBasicType TPtr -> return "Ptr"
   TByteArray -> return "ByteArray"
   TGHash _ _ -> return "Hash"
   TVariant -> return "Variant"
   TParamSpec -> return "ParamSpec"
   TBasicType TInt -> case sizeOf (0 :: CInt) of
                        4 -> return "Int32"
                        n -> error ("Unsupported `gint' type length: " ++
                                    show n)
   TBasicType TUInt -> case sizeOf (0 :: CUInt) of
                        4 -> return "UInt32"
                        n -> error ("Unsupported `guint' type length: " ++
                                    show n)
   TBasicType TLong -> return "Long"
   TBasicType TULong -> return "ULong"
   TBasicType TInt32 -> return "Int32"
   TBasicType TUInt32 -> return "UInt32"
   TBasicType TInt64 -> return "Int64"
   TBasicType TUInt64 -> return "UInt64"
   TBasicType TBoolean -> return "Bool"
   TBasicType TFloat -> return "Float"
   TBasicType TDouble -> return "Double"
   TBasicType TGType -> return "GType"
   TCArray True _ _ (TBasicType TUTF8) -> return "StringArray"
   TCArray True _ _ (TBasicType TFileName) -> return "StringArray"
   TGList (TBasicType TPtr) -> return "PtrGList"
   t@(TInterface ns n) -> do
     api <- findAPIByName (Name ns n)
     case api of
       APIEnum _ -> return "Enum"
       APIFlags _ -> return "Flags"
       APIStruct s -> if structIsBoxed s
                      then return "Boxed"
                      else error $ "Unboxed struct property : " ++ show t
       APIUnion u -> if unionIsBoxed u
                     then return "Boxed"
                     else error $ "Unboxed union property : " ++ show t
       APIObject _ -> do
                isGO <- isGObject t
                if isGO
                then return "Object"
                else error $ "Non-GObject object property : " ++ show t
       APIInterface _ -> do
                isGO <- isGObject t
                if isGO
                then return "Object"
                else error $ "Non-GObject interface property : " ++ show t
       _ -> error $ "Unknown interface property of type : " ++ show t
   _ -> error $ "Don't know how to handle properties of type " ++ show t

-- | Given a property, return the set of constraints on the types, and
-- the type variables for the object and its value.
attrType :: Property -> CodeGen ([Text], Text)
attrType prop = do
  (_,t,constraints) <- argumentType ['a'..'l'] $ propType prop
  return (constraints, t)

genPropertySetter :: Name -> Text -> Property -> CodeGen ()
genPropertySetter n pName prop = group $ do
  let oName = upperName n
  (constraints, t) <- attrType prop
  isNullable <- typeIsNullable (propType prop)
  let constraints' = "MonadIO m":(classConstraint oName <> " o"):constraints
  tStr <- propTypeStr $ propType prop
  line $ "set" <> pName <> " :: (" <> T.intercalate ", " constraints'
           <> ") => o -> " <> t <> " -> m ()"
  line $ "set" <> pName <> " obj val = liftIO $ setObjectProperty" <> tStr
           <> " obj \"" <> propName prop
           <> if isNullable
              then "\" (Just val)"
              else "\" val"

genPropertyGetter :: Name -> Text -> Property -> CodeGen ()
genPropertyGetter n pName prop = group $ do
  let oName = upperName n
  isNullable <- typeIsNullable (propType prop)
  let isMaybe = isNullable && propReadNullable prop /= Just False
  constructorType <- haskellType (propType prop)
  tStr <- propTypeStr $ propType prop
  let constraints = "(MonadIO m, " <> classConstraint oName <> " o)"
      outType = if isMaybe
                then maybeT constructorType
                else constructorType
      getter = if isNullable && not isMaybe
               then "checkUnexpectedNothing \"get" <> pName
                        <> "\" $ getObjectProperty" <> tStr
               else "getObjectProperty" <> tStr
  line $ "get" <> pName <> " :: " <> constraints <>
                " => o -> " <> tshow ("m" `con` [outType])
  line $ "get" <> pName <> " obj = liftIO $ " <> getter
           <> " obj \"" <> propName prop <> "\"" <>
           if tStr `elem` ["Object", "Boxed"]
           then " " <> tshow constructorType -- These require the constructor.
           else ""

genPropertyConstructor :: Name -> Text -> Property -> CodeGen ()
genPropertyConstructor n pName prop = group $ do
  let oName = upperName n
  (constraints, t) <- attrType prop
  tStr <- propTypeStr $ propType prop
  isNullable <- typeIsNullable (propType prop)
  let constraints' = (classConstraint oName <> " o") : constraints
      pconstraints = parenthesize (T.intercalate ", " constraints') <> " => "
  line $ "construct" <> pName <> " :: " <> pconstraints
           <> t <> " -> IO (GValueConstruct o)"
  line $ "construct" <> pName <> " val = constructObjectProperty" <> tStr
           <> " \"" <> propName prop
           <> if isNullable
              then "\" (Just val)"
              else "\" val"

genPropertyClear :: Name -> Text -> Property -> CodeGen ()
genPropertyClear n pName prop = group $ do
  let oName = upperName n
  nothingType <- tshow . maybeT <$> haskellType (propType prop)
  let constraints = ["MonadIO m", classConstraint oName <> " o"]
  tStr <- propTypeStr $ propType prop
  line $ "clear" <> pName <> " :: (" <> T.intercalate ", " constraints
           <> ") => o -> m ()"
  line $ "clear" <> pName <> " obj = liftIO $ setObjectProperty" <> tStr
           <> " obj \"" <> propName prop <> "\" (Nothing :: "
           <> nothingType <> ")"

-- | The property name as a lexically valid Haskell identifier. Note
-- that this is not escaped, since it is assumed that it will be used
-- with a prefix, so if a property is named "class", for example, this
-- will return "class".
hPropName :: Property -> Text
hPropName = lcFirst . hyphensToCamelCase . propName

genObjectProperties :: Name -> Object -> CodeGen ()
genObjectProperties n o = do
  isGO <- apiIsGObject n (APIObject o)
  -- We do not generate bindings for objects not descending from GObject.
  when isGO $ do
    allProps <- fullObjectPropertyList n o >>=
                mapM (\(owner, prop) -> do
                        pi <- infoType owner prop
                        return $ "'(\"" <> hPropName prop
                                   <> "\", " <> pi <> ")")
    genProperties n (objProperties o) allProps

genInterfaceProperties :: Name -> Interface -> CodeGen ()
genInterfaceProperties n iface = do
  allProps <- fullInterfacePropertyList n iface >>=
                mapM (\(owner, prop) -> do
                        pi <- infoType owner prop
                        return $ "'(\"" <> hPropName prop
                                   <> "\", " <> pi <> ")")
  genProperties n (ifProperties iface) allProps

-- If the given accesor is available (indicated by available == True),
-- generate a fully qualified accesor name, otherwise just return
-- "undefined". accessor is "get", "set" or "construct"
accessorOrUndefined :: Bool -> Text -> Name -> Text -> CodeGen Text
accessorOrUndefined available accessor owner@(Name _ on) cName =
    if not available
    then return "undefined"
    else qualifiedSymbol (accessor <> on <> cName) owner

-- | The name of the type encoding the information for the property of
-- the object.
infoType :: Name -> Property -> CodeGen Text
infoType owner prop =
    let infoType = upperName owner <> (hyphensToCamelCase . propName) prop
                   <> "PropertyInfo"
    in qualifiedSymbol infoType owner

genOneProperty :: Name -> Property -> ExcCodeGen ()
genOneProperty owner prop = do
  let name = upperName owner
      cName = (hyphensToCamelCase . propName) prop
      pName = name <> cName
      flags = propFlags prop
      writable = PropertyWritable `elem` flags &&
                 (PropertyConstructOnly `notElem` flags)
      readable = PropertyReadable `elem` flags
      constructOnly = PropertyConstructOnly `elem` flags

  -- For properties the meaning of having transfer /= TransferNothing
  -- is not clear (what are the right semantics for GValue setters?),
  -- and the other possibilities are very uncommon, so let us just
  -- assume that TransferNothing is always the case.
  when (propTransfer prop /= TransferNothing) $
       notImplementedError $ "Property " <> pName
                               <> " has unsupported transfer type "
                               <> tshow (propTransfer prop)

  isNullable <- typeIsNullable (propType prop)

  getter <- accessorOrUndefined readable "get" owner cName
  setter <- accessorOrUndefined writable "set" owner cName
  constructor <- accessorOrUndefined (writable || constructOnly)
                 "construct" owner cName
  clear <- accessorOrUndefined (isNullable && writable &&
                                propWriteNullable prop /= Just False)
           "clear" owner cName

  unless (readable || writable || constructOnly) $
       notImplementedError $ "Property is not readable, writable, or constructible: "
                               <> tshow pName

  group $ do
    line $ "-- VVV Prop \"" <> propName prop <> "\""
    line $ "   -- Type: " <> tshow (propType prop)
    line $ "   -- Flags: " <> tshow (propFlags prop)
    line $ "   -- Nullable: " <> tshow (propReadNullable prop,
                                        propWriteNullable prop)

  when readable $ genPropertyGetter owner pName prop
  when writable $ genPropertySetter owner pName prop
  when (writable || constructOnly) $ genPropertyConstructor owner pName prop
  when (isNullable && writable && propWriteNullable prop /= Just False) $
       genPropertyClear owner pName prop
  when (getter /= "undefined") (exportProperty cName getter)
  when (setter /= "undefined") (exportProperty cName setter)
  when (constructor /= "undefined") (exportProperty cName constructor)
  when (clear /= "undefined") (exportProperty cName clear)

-- | Generate a placeholder property for those cases in which code
-- generation failed.
genPlaceholderProperty :: Name -> Property -> CodeGen ()
genPlaceholderProperty owner prop = do
  line $ "-- XXX Placeholder"
  it <- infoType owner prop
  let cName = (hyphensToCamelCase . propName) prop
  exportProperty cName it
  line $ "data " <> it
  line $ "instance AttrInfo " <> it <> " where"
  indent $ do
    line $ "type AttrAllowedOps " <> it <> " = '[]"
    line $ "type AttrSetTypeConstraint " <> it <> " = (~) ()"
    line $ "type AttrBaseTypeConstraint " <> it <> " = (~) ()"
    line $ "type AttrGetType " <> it <> " = ()"
    line $ "type AttrLabel " <> it <> " = \"\""
    line $ "attrGet = undefined"
    line $ "attrSet = undefined"
    line $ "attrConstruct = undefined"
    line $ "attrClear = undefined"

genProperties :: Name -> [Property] -> [Text] -> CodeGen ()
genProperties n ownedProps allProps = do
  let name = upperName n

  forM_ ownedProps $ \prop -> do
      handleCGExc (\err -> do
                     line $ "-- XXX Generation of property \""
                              <> propName prop <> "\" of object \""
                              <> name <> "\" failed: " <> describeCGError err)
                  (genOneProperty n prop)

-- | Generate gtk2hs compatible attribute labels (to ease
-- porting). These are namespaced labels, for examples
-- `widgetSensitive`. We take the list of methods, since there may be
-- name clashes (an example is Auth::is_for_proxy method in libsoup,
-- and the corresponding Auth::is-for-proxy property). When there is a
-- clash we give priority to the method.
genNamespacedPropLabels :: Name -> [Property] -> [Method] -> CodeGen ()
genNamespacedPropLabels owner props methods =
    let lName = lcFirst . hyphensToCamelCase . propName
    in genNamespacedAttrLabels owner (map lName props) methods

genNamespacedAttrLabels :: Name -> [Text] -> [Method] -> CodeGen ()
genNamespacedAttrLabels owner attrNames methods = do
  let name = upperName owner

  let methodNames = S.fromList (map (lowerName . methodName) methods)
      filteredAttrs = filter (`S.notMember` methodNames) attrNames

  forM_ filteredAttrs $ \attr -> group $ do
    let cName = ucFirst attr
        labelProxy = lcFirst name <> cName

    line $ labelProxy <> " :: AttrLabelProxy \"" <> lcFirst cName <> "\""
    line $ labelProxy <> " = AttrLabelProxy"

    exportProperty cName labelProxy
