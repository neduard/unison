{-# LANGUAGE DataKinds #-}

module Unison.LSP.Formatting where

import Control.Lens hiding (List)
import Data.IntervalMap.Interval qualified as Interval
import Data.List.NonEmpty.Extra qualified as NEL
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Language.LSP.Protocol.Lens
import Language.LSP.Protocol.Message qualified as Msg
import Language.LSP.Protocol.Types
import Unison.Codebase.Path qualified as Path
import Unison.DataDeclaration qualified as Decl
import Unison.HashQualified qualified as HQ
import Unison.LSP.Conversions (annToInterval, annToRange, rangeToInterval)
import Unison.LSP.FileAnalysis (getFileAnalysis, hasUserTypeSignature)
import Unison.LSP.FileAnalysis qualified as FileAnalysis
import Unison.LSP.Types
import Unison.Name qualified as Name
import Unison.Parser.Ann qualified as Ann
import Unison.Prelude
import Unison.PrettyPrintEnv.Util qualified as PPE
import Unison.PrettyPrintEnvDecl qualified as PPED
import Unison.Reference qualified as Reference
import Unison.Symbol (Symbol)
import Unison.Syntax.DeclPrinter qualified as DeclPrinter
import Unison.Syntax.Name qualified as Name
import Unison.Syntax.TermPrinter qualified as TermPrinter
import Unison.Term qualified as Term
import Unison.UnisonFile (TypecheckedUnisonFile, UnisonFile)
import Unison.Util.Pretty qualified as Pretty

formatDocRequest :: Msg.TRequestMessage 'Msg.Method_TextDocumentFormatting -> (Either Msg.ResponseError (Msg.MessageResult 'Msg.Method_TextDocumentFormatting) -> Lsp ()) -> Lsp ()
formatDocRequest m respond = do
  edits <- formatDefs (m ^. params . textDocument . uri) Nothing
  respond . Right . InL $ edits

formatRangeRequest :: Msg.TRequestMessage 'Msg.Method_TextDocumentRangeFormatting -> (Either Msg.ResponseError (Msg.MessageResult 'Msg.Method_TextDocumentRangeFormatting) -> Lsp ()) -> Lsp ()
formatRangeRequest m respond = do
  let p = m ^. params
  edits <- formatDefs (p ^. textDocument . uri) (Just . Set.singleton $ p ^. range)
  respond . Right . InL $ edits

-- | Format all definitions in a file.
formatDefs :: Uri -> Maybe (Set Range {- the ranges to format, if Nothing then format the whole file. -}) -> Lsp [TextEdit]
formatDefs fileUri mayRangesToFormat =
  fromMaybe []
    <$> runMaybeT do
      cwd <- lift getCurrentPath
      FileAnalysis {parsedFile = mayParsedFile, typecheckedFile = mayTypecheckedFile} <- getFileAnalysis fileUri
      (mayParsedFile, mayTypecheckedFile) <- lift $ mkUnisonFilesDeterministic mayParsedFile mayTypecheckedFile
      fileSummary <- hoistMaybe $ FileAnalysis.mkFileSummary mayParsedFile mayTypecheckedFile
      filePPED <- lift $ FileAnalysis.ppedForFileHelper mayParsedFile mayTypecheckedFile
      parsedFile <- hoistMaybe mayParsedFile
      formattedDecls <-
        (allTypeDecls fileSummary)
          & fmap
            ( \(ref, decl) ->
                let tldAnn = either (Decl.annotation . Decl.toDataDecl) (Decl.annotation) decl
                 in (tldAnn, ref, decl)
            )
          & Map.filter (\(tldAnn, _, _) -> shouldFormatTLD tldAnn)
          & itraverse \sym (tldAnn, ref, decl) -> do
            symName <- hoistMaybe (Name.fromVar sym)
            let declNameSegments = NEL.appendr (Path.toList (Path.unabsolute cwd)) (Name.segments symName)
            let declName = Name.fromSegments declNameSegments
            let hqName = HQ.fromName symName
            let biasedPPED = PPED.biasTo [declName] filePPED
            -- If it's a unique type the parser will re-order constructors arbitrarily because
            -- the random unique seed gets mixed in and then things are ordered by hash.
            --
            -- The constructor order will always be re-ordered on definition Add anyways, so we
            -- just force alphabetical order for unique types for sanity reasons.
            -- Doesn't work unless we alter it before building the pped
            -- let deterministicDecl = decl & Decl.declAsDataDecl_ . Decl.constructors_ %~ sortOn (view _1)
            pure $
              (tldAnn, DeclPrinter.prettyDecl biasedPPED (Reference.DerivedId ref) hqName decl)
                & over _2 Pretty.syntaxToColor
      formattedTerms <-
        (termsBySymbol fileSummary)
          & Map.filter (\(tldAnn, _, _, _) -> shouldFormatTLD tldAnn)
          & itraverse \sym (tldAnn, mayRefId, trm, _typ) -> do
            symName <- hoistMaybe (Name.fromVar sym)
            let defNameSegments = NEL.appendr (Path.toList (Path.unabsolute cwd)) (Name.segments symName)
            let defName = Name.fromSegments defNameSegments
            let hqName = HQ.NameOnly symName
            let biasedPPED = PPED.biasTo [defName] filePPED
            let definitionPPE = case mayRefId of
                  Just refId -> PPE.declarationPPE biasedPPED (Reference.DerivedId refId)
                  Nothing -> PPED.suffixifiedPPE biasedPPED
            let formattedTerm = Pretty.syntaxToColor $ TermPrinter.prettyBinding definitionPPE hqName (removeGeneratedTypeAnnotations parsedFile sym trm)
            -- TODO: format watch expressions and test watches
            -- let formattedWatches =
            --       allWatches fileSummary & map \(_tldAnn, maySym, _mayRef, trm, _mayType, mayWatchKind) -> do
            --         case (mayWatchKind, maySym) of
            --           (Just wk, Just (Symbol.Symbol _ (Var.User {}))) ->
            --             -- Watch with binding
            --             Pretty.syntaxToColor $ Pretty.string wk <> "> " <> TermPrinter.prettyBindingWithoutTypeSignature definitionPPE hqName (stripTypeAnnotation trm)
            --           (Just wk, _) -> Pretty.string wk <> "> " <> TermPrinter.prettyBlock False definitionPPE (stripTypeAnnotation trm)
            --           (Nothing, _) -> "> " <> TermPrinter.prettyBlock False definitionPPE (stripTypeAnnotation trm)
            pure (tldAnn, formattedTerm)

      -- Only keep definitions which are _actually_ in the file, skipping generated accessors
      -- and such.
      let nonGeneratedDefs =
            (formattedTerms <> formattedDecls)
              & mapMaybe
                ( \case
                    (Ann.Ann {start, end}, txt) -> Just ((start, end), txt)
                    _ -> Nothing
                )
      -- when (null filteredDefs) empty {- Don't format if we have no definitions or it wipes out the fold! -}
      Config {formattingWidth} <- lift getConfig
      let textEdits =
            nonGeneratedDefs & foldMap \((start, end), txt) -> do
              range <- maybeToList $ annToRange (Ann.Ann start end)
              pure $ TextEdit range (Text.pack $ Pretty.toPlain (Pretty.Width formattingWidth) txt)
      pure textEdits
  where
    shouldFormatTLD :: Ann.Ann -> Bool
    shouldFormatTLD ann =
      case mayRangesToFormat of
        Nothing -> True
        Just rangesToFormat -> any (annRangeOverlap ann) rangesToFormat
    -- Does the given range overlap with the given annotation?
    annRangeOverlap :: Ann.Ann -> Range -> Bool
    annRangeOverlap a r =
      annToInterval a & \case
        Nothing -> False
        Just annI -> rangeToInterval r `Interval.overlaps` annI

    -- Typechecking ALWAYS adds a type-signature, but we don't want to add ones that didn't
    -- already exist in the source file.
    removeGeneratedTypeAnnotations ::
      UnisonFile Symbol a -> Symbol -> (Term.Term Symbol a) -> (Term.Term Symbol a)
    removeGeneratedTypeAnnotations uf v = \case
      Term.Ann' tm _annotation | not (hasUserTypeSignature uf v) -> tm
      x -> x

    -- This is a bit of a hack.
    -- The file parser uses a different unique ID for unique types on every parse,
    -- that id changes hashes, and constructors are ordered by that hash.
    -- This means that pretty-printing isn't deterministic and constructors will re-order
    -- themselves on every save :|
    --
    -- It's difficult and a bad idea to change the parser to use a deterministic unique ID,
    -- so instead we just re-sort the constructors by their source-file annotation AFTER
    -- parsing. This is fine for pretty-printing, but don't use this for anything other than
    -- formatting since the Decls it produces aren't technically valid.
    mkUnisonFilesDeterministic :: Maybe (UnisonFile Symbol Ann.Ann) -> Maybe (TypecheckedUnisonFile Symbol Ann.Ann) -> Lsp (Maybe (UnisonFile Symbol Ann.Ann), Maybe (TypecheckedUnisonFile Symbol Ann.Ann))
    mkUnisonFilesDeterministic mayUnisonFile mayTypecheckedFile = do
      let sortedUF =
            mayUnisonFile
              & _Just . #dataDeclarationsId . traversed . _2 %~ sortConstructors
              & _Just . #effectDeclarationsId . traversed . _2 . Decl.asDataDecl_ %~ sortConstructors
      let sortedTF =
            mayTypecheckedFile
              & _Just . #dataDeclarationsId' . traversed . _2 %~ sortConstructors
              & _Just . #effectDeclarationsId' . traversed . _2 . Decl.asDataDecl_ %~ sortConstructors
      pure (sortedUF, sortedTF)

    -- ppedForFileHelper
    sortConstructors :: Decl.DataDeclaration v Ann.Ann -> Decl.DataDeclaration v Ann.Ann
    sortConstructors dd =
      -- Sort by their Ann so we keep the order they were in the original file.
      dd & Decl.constructors_ %~ sortOn @Ann.Ann (view _1)
