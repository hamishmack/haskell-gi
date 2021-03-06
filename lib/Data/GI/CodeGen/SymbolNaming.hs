{-# LANGUAGE ViewPatterns #-}
module Data.GI.CodeGen.SymbolNaming
    ( lowerName
    , upperName
    , noName
    , escapedArgName

    , classConstraint
    , typeConstraint

    , hyphensToCamelCase
    , underscoresToCamelCase

    , submoduleLocation
    , qualifiedAPI
    , qualifiedSymbol
    ) where

import Data.Monoid ((<>))
import Data.Text (Text)
import qualified Data.Text as T

import Data.GI.CodeGen.API
import Data.GI.CodeGen.Code (CodeGen, ModuleName, group, line, exportDecl,
                             qualified, getAPI)
import Data.GI.CodeGen.Type (Type(TInterface))
import Data.GI.CodeGen.Util (lcFirst, ucFirst)

-- | Return a qualified form of the constraint for the given name
-- (which should correspond to a valid `TInterface`).
classConstraint :: Name -> CodeGen Text
classConstraint n@(Name _ s) = qualifiedSymbol ("Is" <> s) n

-- | Same as `classConstraint`, but applicable directly to a type. The
-- type should be a `TInterface`, otherwise an error will be raised.
typeConstraint :: Type -> CodeGen Text
typeConstraint (TInterface ns s) = classConstraint (Name ns s)
typeConstraint t = error $ "Class constraint for non-interface type: " <> show t

-- | Move leading underscores to the end (for example in
-- GObject::_Value_Data_Union -> GObject::Value_Data_Union_)
sanitize :: Text -> Text
sanitize (T.uncons -> Just ('_', xs)) = sanitize xs <> "_"
sanitize xs = xs

lowerName :: Name -> Text
lowerName (Name _ s) =
    case underscoresToCamelCase (sanitize s) of
      "" -> error "empty name!!"
      n -> lcFirst n

upperName :: Name -> Text
upperName (Name _ s) = underscoresToCamelCase (sanitize s)

-- | Return an identifier for the given interface type valid in the current
-- module.
qualifiedAPI :: Name -> CodeGen Text
qualifiedAPI n@(Name ns s) = do
  api <- getAPI (TInterface ns s)
  qualified ("GI" : ucFirst ns : submoduleLocation n api) n

-- | Construct an identifier for the given symbol in the given API.
qualifiedSymbol :: Text -> Name -> CodeGen Text
qualifiedSymbol s n@(Name ns nn) = do
  api <- getAPI (TInterface ns nn)
  qualified ("GI" : ucFirst ns : submoduleLocation n api) (Name ns s)

-- | Construct the submodule name (as a list, to be joined by
-- intercalating ".") where the given API element will live. This is
-- the path relative to the root for the corresponding
-- namespace. I.e. the "GI.Gtk" part is not prepended.
submoduleLocation :: Name -> API -> ModuleName
submoduleLocation _ (APIConst _) = ["Constants"]
submoduleLocation _ (APIFunction _) = ["Functions"]
submoduleLocation _ (APICallback _) = ["Callbacks"]
submoduleLocation _ (APIEnum _) = ["Enums"]
submoduleLocation _ (APIFlags _) = ["Flags"]
submoduleLocation n (APIInterface _) = ["Interfaces", upperName n]
submoduleLocation n (APIObject _) = ["Objects", upperName n]
submoduleLocation n (APIStruct _) = ["Structs", upperName n]
submoduleLocation n (APIUnion _) = ["Unions", upperName n]

-- | Save a bit of typing for optional arguments in the case that we
-- want to pass Nothing.
noName :: Text -> CodeGen ()
noName name' = group $ do
                 line $ "no" <> name' <> " :: Maybe " <> name'
                 line $ "no" <> name' <> " = Nothing"
                 exportDecl ("no" <> name')

-- | For a string of the form "one-sample-string" return "OneSampleString"
hyphensToCamelCase :: Text -> Text
hyphensToCamelCase = T.concat . map ucFirst . T.split (== '-')

-- | Similarly, turn a name separated_by_underscores into
-- CamelCase. We preserve final and initial underscores, and n>1
-- consecutive underscores are transformed into n-1 underscores.
underscoresToCamelCase :: Text -> Text
underscoresToCamelCase =
    T.concat . map normalize . map ucFirst . T.split (== '_')
        where normalize :: Text -> Text
              normalize "" = "_"
              normalize s = s

-- | Name for the given argument, making sure it is a valid Haskell
-- argument name (and escaping it if not).
escapedArgName :: Arg -> Text
escapedArgName arg
    | "_" `T.isPrefixOf` argCName arg = argCName arg
    | otherwise =
        escapeReserved . lcFirst . underscoresToCamelCase . argCName $ arg

-- | Reserved symbols, either because they are Haskell syntax or
-- because the clash with symbols in scope for the generated bindings.
escapeReserved :: Text -> Text
escapeReserved "type" = "type_"
escapeReserved "in" = "in_"
escapeReserved "data" = "data_"
escapeReserved "instance" = "instance_"
escapeReserved "where" = "where_"
escapeReserved "module" = "module_"
-- Reserved because we generate code that uses these names.
escapeReserved "result" = "result_"
escapeReserved "return" = "return_"
escapeReserved "show" = "show_"
escapeReserved "fromEnum" = "fromEnum_"
escapeReserved "toEnum" = "toEnum_"
escapeReserved "undefined" = "undefined_"
escapeReserved "error" = "error_"
escapeReserved "map" = "map_"
escapeReserved "length" = "length_"
escapeReserved "mapM" = "mapM__"
escapeReserved "mapM_" = "mapM___"
escapeReserved "fromIntegral" = "fromIntegral_"
escapeReserved "realToFrac" = "realToFrac_"
escapeReserved "peek" = "peek_"
escapeReserved "poke" = "poke_"
escapeReserved "sizeOf" = "sizeOf_"
escapeReserved "when" = "when_"
escapeReserved "default" = "default_"
escapeReserved s
    | "set_" `T.isPrefixOf` s = s <> "_"
    | "get_" `T.isPrefixOf` s = s <> "_"
    | otherwise = s
