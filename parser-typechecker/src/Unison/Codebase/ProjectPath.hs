module Unison.Codebase.ProjectPath
  ( ProjectPathG (..),
    ProjectPathIds,
    ProjectPathNames,
    ProjectPath,
    fromProjectAndBranch,
    absPath_,
    path_,
    projectAndBranch_,
    toText,
    toIds,
    toNames,
    asProjectAndBranch_,
    projectPathParser,
    parseProjectPath,
  )
where

import Control.Lens
import Data.Bifoldable (Bifoldable (..))
import Data.Bitraversable (Bitraversable (..))
import Data.Text qualified as Text
import Text.Megaparsec qualified as Megaparsec
import Text.Megaparsec.Char qualified as Megaparsec
import U.Codebase.Sqlite.DbId (ProjectBranchId, ProjectId)
import U.Codebase.Sqlite.Project (Project (..))
import U.Codebase.Sqlite.ProjectBranch (ProjectBranch (..))
import Unison.Codebase.Path qualified as Path
import Unison.Codebase.Path.Parse qualified as Path
import Unison.Prelude
import Unison.Project (ProjectAndBranch (..), ProjectBranchName, ProjectName)
import Unison.Project qualified as Project

data ProjectPathG proj branch = ProjectPath
  { project :: proj,
    branch :: branch,
    absPath :: Path.Absolute
  }
  deriving stock (Eq, Ord, Show, Generic)

type ProjectPathIds = ProjectPathG ProjectId ProjectBranchId

type ProjectPathNames = ProjectPathG ProjectName ProjectBranchName

type ProjectPath = ProjectPathG Project ProjectBranch

fromProjectAndBranch :: ProjectAndBranch Project ProjectBranch -> Path.Absolute -> ProjectPath
fromProjectAndBranch (ProjectAndBranch proj branch) path = ProjectPath proj branch path

-- | Project a project context into a project path of just IDs
toIds :: ProjectPath -> ProjectPathIds
toIds (ProjectPath proj branch path) = ProjectPath (proj ^. #projectId) (branch ^. #branchId) path

-- | Project a project context into a project path of just names
toNames :: ProjectPath -> ProjectPathNames
toNames (ProjectPath proj branch path) = ProjectPath (proj ^. #name) (branch ^. #name) path

asProjectAndBranch_ :: Lens' ProjectPath (ProjectAndBranch Project ProjectBranch)
asProjectAndBranch_ = lens get set
  where
    get (ProjectPath proj branch _) = ProjectAndBranch proj branch
    set p (ProjectAndBranch proj branch) = p & #project .~ proj & #branch .~ branch

instance Bifunctor ProjectPathG where
  bimap f g (ProjectPath p b path) = ProjectPath (f p) (g b) path

instance Bifoldable ProjectPathG where
  bifoldMap f g (ProjectPath p b _) = f p <> g b

instance Bitraversable ProjectPathG where
  bitraverse f g (ProjectPath p b path) = ProjectPath <$> f p <*> g b <*> pure path

toText :: ProjectPathG Project ProjectBranch -> Text
toText (ProjectPath proj branch path) =
  into @Text (proj ^. #name) <> "/" <> into @Text (branch ^. #name) <> ":" <> Path.absToText path

absPath_ :: Lens' (ProjectPathG p b) Path.Absolute
absPath_ = lens go set
  where
    go (ProjectPath _ _ p) = p
    set (ProjectPath n b _) p = ProjectPath n b p

path_ :: Lens' (ProjectPathG p b) Path.Path
path_ = absPath_ . Path.absPath_

projectAndBranch_ :: Lens' (ProjectPathG p b) (ProjectAndBranch p b)
projectAndBranch_ = lens go set
  where
    go (ProjectPath proj branch _) = ProjectAndBranch proj branch
    set (ProjectPath _ _ p) (ProjectAndBranch proj branch) = ProjectPath proj branch p

type Parser = Megaparsec.Parsec Void Text

projectPathParser :: Parser ProjectPathNames
projectPathParser = do
  (projName, hasTrailingSlash) <- Project.projectNameParser
  projBranchName <- Project.projectBranchNameParser (not hasTrailingSlash)
  _ <- Megaparsec.char ':'
  path' >>= \case
    Path.AbsolutePath' p -> pure $ ProjectPath projName projBranchName p
    Path.RelativePath' {} -> fail "Expected an absolute path"
  where
    path' :: Parser Path.Path'
    path' = do
      pathStr <- Megaparsec.takeRest
      case Path.parsePath' (Text.unpack pathStr) of
        Left err -> fail (Text.unpack err)
        Right x -> pure x

parseProjectPath :: Text -> Either Text ProjectPathNames
parseProjectPath txt = first (Text.pack . Megaparsec.errorBundlePretty) $ Megaparsec.parse projectPathParser "" txt
