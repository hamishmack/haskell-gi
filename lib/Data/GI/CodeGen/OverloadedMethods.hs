module Data.GI.CodeGen.OverloadedMethods
    ( genMethodList
    , genMethodInfo
    , genUnsupportedMethodInfo
    ) where

import Control.Monad (forM, forM_, when)
import Data.Monoid ((<>))
import Data.Text (Text)
import qualified Data.Text as T

import Data.GI.CodeGen.API
import Data.GI.CodeGen.Callable (callableSignature, fixupCallerAllocates)
import Data.GI.CodeGen.Code
import Data.GI.CodeGen.SymbolNaming (lowerName, upperName, qualifiedSymbol)
import Data.GI.CodeGen.Util (ucFirst)

-- | Qualified name for the info for a given method.
methodInfoName :: Name -> Method -> CodeGen Text
methodInfoName n method =
    let infoName = upperName n <> (ucFirst . lowerName . methodName) method
                   <> "MethodInfo"
    in qualifiedSymbol infoName n

-- | Appropriate instances so overloaded labels are properly resolved.
genMethodResolver :: Text -> CodeGen ()
genMethodResolver n = do
  group $ do
    line $ "instance (info ~ Resolve" <> n <> "Method t " <> n <> ", "
          <> "MethodInfo info " <> n <> " p) => IsLabelProxy t ("
          <> n <> " -> p) where"
    indent $ line $ "fromLabelProxy _ = overloadedMethod (MethodProxy :: MethodProxy info)"
  group $ do
    line $ "#if MIN_VERSION_base(4,9,0)"
    line $ "instance (info ~ Resolve" <> n <> "Method t " <> n <> ", "
          <> "MethodInfo info " <> n <> " p) => IsLabel t ("
          <> n <> " -> p) where"
    indent $ line $ "fromLabel _ = overloadedMethod (MethodProxy :: MethodProxy info)"
    line $ "#endif"

-- | Generate the `MethodList` instance given the list of methods for
-- the given named type.
genMethodList :: Name -> [(Name, Method)] -> CodeGen ()
genMethodList n methods = do
  let name = upperName n
  let filteredMethods = filter isOrdinaryMethod methods
      gets = filter isGet filteredMethods
      sets = filter isSet filteredMethods
      others = filter (\m -> not (isSet m || isGet m)) filteredMethods
      orderedMethods = others ++ gets ++ sets
  infos <- forM orderedMethods $ \(owner, method) ->
           do mi <- methodInfoName owner method
              return ((lowerName . methodName) method, mi)
  group $ do
    let resolver = "Resolve" <> name <> "Method"
    line $ "type family " <> resolver <> " (t :: Symbol) (o :: *) :: * where"
    indent $ forM_ infos $ \(label, info) -> do
        line $ resolver <> " \"" <> label <> "\" o = " <> info
    indent $ line $ resolver <> " l o = MethodResolutionFailed l o"

  genMethodResolver name

  where isOrdinaryMethod :: (Name, Method) -> Bool
        isOrdinaryMethod (_, m) = methodType m == OrdinaryMethod

        isGet :: (Name, Method) -> Bool
        isGet (_, m) = "get_" `T.isPrefixOf` (name . methodName) m

        isSet :: (Name, Method) -> Bool
        isSet (_, m) = "set_" `T.isPrefixOf` (name . methodName) m

-- | Generate the `MethodInfo` type and instance for the given method.
genMethodInfo :: Name -> Method -> ExcCodeGen ()
genMethodInfo n m =
    when (methodType m == OrdinaryMethod) $
      group $ do
        infoName <- methodInfoName n m
        let callable = fixupCallerAllocates (methodCallable m)
        (constraints, types) <- callableSignature callable (methodThrows m)
        bline $ "data " <> infoName
        -- This should not happen, since ordinary methods always
        -- have the instance as first argument.
        when (null types) $
          error $ "Internal error: too few parameters! " ++ show m
        let (obj:otherTypes) = map fst types
            sigConstraint = "signature ~ (" <> T.intercalate " -> " otherTypes
                            <> ")"
        line $ "instance (" <> T.intercalate ", " (sigConstraint : constraints)
                 <> ") => MethodInfo " <> infoName <> " " <> obj <> " signature where"
        let mn = methodName m
            mangled = lowerName (mn {name = name n <> "_" <> name mn})
        indent $ line $ "overloadedMethod _ = " <> mangled
        exportMethod mangled infoName

-- | Generate a method info that is not actually callable, but rather
-- gives a type error when trying to use it.
genUnsupportedMethodInfo :: Name -> Method -> CodeGen ()
genUnsupportedMethodInfo n m = return ()
