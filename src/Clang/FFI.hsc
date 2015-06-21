module Clang.FFI where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Clang.Context
import Clang.Refs
import Clang.Types
import Control.Exception
import Control.Lens
import Control.Lens.Internal (noEffect)
import Control.Monad
import Data.Foldable
import Data.IORef
import qualified Data.Vector.Storable as VS
import Foreign
import Foreign.C
import qualified Language.C.Inline as C hiding (exp, block)
import qualified Language.C.Inline as CSafe
import qualified Language.C.Inline.Unsafe as C
import System.IO.Unsafe

C.context clangCtx
C.include "stdlib.h"
#include  "clang-c/Index.h"
C.include "clang-c/Index.h"
C.include "utils.h"

foreign import ccall "clang_disposeIndex"
  clang_disposeIndex :: Ptr CXIndexImpl -> Finalizer

createIndex :: IO ClangIndex
createIndex = do
  idxp <- [C.exp| CXIndex { clang_createIndex(0, 1) } |]
  ClangIndex <$> root (clang_disposeIndex idxp) idxp

foreign import ccall "clang_disposeTranslationUnit"
  clang_disposeTranslationUnit :: Ptr CXTranslationUnitImpl -> Finalizer

data ClangError
  = Success
  | Failure
  | Crashed
  | InvalidArguments
  | ASTReadError
  deriving (Eq, Ord, Show)

parseClangError :: CInt -> ClangError
parseClangError = \case
  #{const CXError_Success} -> Success
  #{const CXError_Failure} -> Failure
  #{const CXError_Crashed} -> Crashed
  #{const CXError_InvalidArguments} -> InvalidArguments
  #{const CXError_ASTReadError} -> ASTReadError
  _ -> Failure -- unrecognized enum value

instance Exception ClangError

parseTranslationUnit :: ClangIndex -> String -> [ String ] -> IO TranslationUnit
parseTranslationUnit idx path args = do
  tun <- child idx $ \idxp -> 
    withCString path $ \cPath -> do
      cArgs <- VS.fromList <$> traverse newCString args
      ( tup, cres ) <- C.withPtr $ \tupp -> [C.exp| int {
        clang_parseTranslationUnit2(
          $(CXIndex idxp),
          $(char* cPath),
          $vec-ptr:(const char * const * cArgs), $vec-len:cArgs,
          NULL, 0,
          0,
          $(CXTranslationUnit *tupp))
        } |]
      traverse_ free $ VS.toList cArgs
      let res = parseClangError cres
      when (res /= Success) $ throwIO res
      return ( clang_disposeTranslationUnit tup, tup )
  return $ TranslationUnitRef tun

translationUnitCursor :: TranslationUnit -> Cursor
translationUnitCursor tu = unsafePerformIO $ do
  cn <- child tu $ \tup -> do
    cp <- [C.block| CXCursor* { ALLOC(CXCursor,
      clang_getTranslationUnitCursor($(CXTranslationUnit tup))
      )} |]
    return ( free cp, cp )
  return $ Cursor cn

cursorTranslationUnit :: Cursor -> TranslationUnit
cursorTranslationUnit (Cursor c) = parent c

cursorKind :: Cursor -> CursorKind
cursorKind c = uderef c $ \cp ->
  parseCursorKind <$> [C.exp| int { clang_getCursorKind(*$(CXCursor *cp)) } |]

cursorChildren :: Fold Cursor Cursor
cursorChildren f c = uderef c $ \cp -> do
  fRef <- newIORef noEffect
  let 
    visitChild chp = do
      ch <- child (cursorTranslationUnit c) $ \_ ->
        return ( free chp, chp )
      modifyIORef' fRef (*> f (Cursor ch))
  [CSafe.exp| void {
    clang_visitChildren(
      *$(CXCursor *cp),
      visit_haskell,
      $fun:(void (*visitChild)(CXCursor*)))
    } |]
  readIORef fRef

withCXString :: (Ptr CXString -> IO ()) -> IO ByteString
withCXString f = allocaBytes (#size CXString) $ \cxsp -> do
  f cxsp
  cs <- [C.exp| const char * { clang_getCString(*$(CXString *cxsp)) } |]
  s <- BS.packCString cs
  [C.exp| void { clang_disposeString(*$(CXString *cxsp)) } |]
  return s

cursorSpelling :: Cursor -> ByteString
cursorSpelling c = uderef c $ \cp -> withCXString $ \cxsp ->
  [C.block| void {
    *$(CXString *cxsp) = clang_getCursorSpelling(*$(CXCursor *cp));
    } |]

cursorExtent :: Cursor -> Maybe SourceRange
cursorExtent c = uderef c $ \cp -> do
  srp <- [C.block| CXSourceRange* {
    CXSourceRange sr = clang_getCursorExtent(*$(CXCursor *cp));
    if (clang_Range_isNull(sr)) {
      return NULL;
    }

    ALLOC(CXSourceRange, sr);
    } |]
  if srp == nullPtr
    then return Nothing
    else do
      srn <- child (cursorTranslationUnit c) $ \_ ->
        return ( free srp, srp )
      return $ Just $ SourceRange srn

cursorUSR :: Cursor -> ByteString
cursorUSR c = uderef c $ \cp -> withCXString $ \cxsp ->
  [C.block| void {
    *$(CXString *cxsp) = clang_getCursorUSR(*$(CXCursor *cp));
    } |]

cursorReferenced :: Cursor -> Maybe Cursor
cursorReferenced c = uderef c $ \cp -> do
  rcp <- [C.block| CXCursor* {
    CXCursor ref = clang_getCursorReferenced(*$(CXCursor *cp));
    if (clang_Cursor_isNull(ref)) {
      return NULL;
    }

    ALLOC(CXCursor, ref);
    } |]
  if rcp /= nullPtr
    then (Just . Cursor) <$> child (parent c) (\_ -> return ( free rcp, rcp ))
    else return Nothing

rangeStart, rangeEnd :: SourceRange -> SourceLocation
rangeStart sr = uderef sr $ \srp -> do
  slp <- [C.block| CXSourceLocation* { ALLOC(CXSourceLocation,
    clang_getRangeStart(*$(CXSourceRange *srp))
    )} |]
  sln <- child (parent sr) $ \_ ->
    return ( free slp, slp )
  return $ SourceLocation sln

rangeEnd sr = uderef sr $ \srp -> do
  slp <- [C.block| CXSourceLocation* { ALLOC(CXSourceLocation,
    clang_getRangeEnd(*$(CXSourceRange *srp))
    )} |]
  sln <- child (parent sr) $ \_ ->
    return ( free slp, slp )
  return $ SourceLocation sln

spellingLocation :: SourceLocation -> Location
spellingLocation sl = uderef sl $ \slp -> do
  ( f, l, c, o ) <- C.withPtrs_ $ \( fp, lp, cp, offp ) ->
    [C.exp| void {
      clang_getSpellingLocation(
        *$(CXSourceLocation *slp),
        $(CXFile *fp),
        $(unsigned int *lp),
        $(unsigned int *cp),
        $(unsigned int *offp))
      } |]
  fn <- child (parent sl) $ \_ -> return ( return (), f )
  return $ Location
    { file = File fn
    , line = fromIntegral l
    , column = fromIntegral c
    , offset = fromIntegral o
    }

getFile :: TranslationUnit -> FilePath -> Maybe File
getFile tu p = uderef tu $ \tup -> withCString p $ \fn -> do
  fp <- [C.exp| CXFile {
    clang_getFile($(CXTranslationUnit tup), $(const char *fn))
    } |]
  if fp == nullPtr
    then return Nothing
    else (Just . File) <$> child tu (\_ -> return ( return (), fp ))

fileName :: File -> ByteString
fileName f = uderef f $ \fp -> withCXString $ \cxsp ->
  [C.block| void {
    *$(CXString *cxsp) = clang_getFileName($(CXFile fp));
    } |]

instance Eq Cursor where
  (==) = defaultEq $ \lp rp ->
    [C.exp| int { clang_equalCursors(*$(CXCursor *lp), *$(CXCursor *rp)) } |]

instance Eq SourceRange where
  (==) = defaultEq $ \lp rp ->
    [C.exp| int { clang_equalRanges(*$(CXSourceRange *lp), *$(CXSourceRange *rp)) } |]

instance Eq SourceLocation where
  (==) = defaultEq $ \lp rp ->
    [C.exp| int { clang_equalLocations(*$(CXSourceLocation *lp), *$(CXSourceLocation *rp)) } |]

defaultEq :: (Ref r, RefType r ~ a) => (Ptr a -> Ptr a -> IO CInt) -> r -> r -> Bool
defaultEq ne l r
  = node l == node r || uderef2 l r ne /= 0

parseCursorKind :: CInt -> CursorKind
parseCursorKind = \case
  #{const CXCursor_UnexposedDecl} -> UnexposedDecl
  #{const CXCursor_StructDecl} -> StructDecl
  #{const CXCursor_UnionDecl} -> UnionDecl
  #{const CXCursor_ClassDecl} -> ClassDecl
  #{const CXCursor_EnumDecl} -> EnumDecl
  #{const CXCursor_FieldDecl} -> FieldDecl
  #{const CXCursor_EnumConstantDecl} -> EnumConstantDecl
  #{const CXCursor_FunctionDecl} -> FunctionDecl
  #{const CXCursor_VarDecl} -> VarDecl
  #{const CXCursor_ParmDecl} -> ParmDecl
  #{const CXCursor_ObjCInterfaceDecl} -> ObjCInterfaceDecl
  #{const CXCursor_ObjCCategoryDecl} -> ObjCCategoryDecl
  #{const CXCursor_ObjCProtocolDecl} -> ObjCProtocolDecl
  #{const CXCursor_ObjCPropertyDecl} -> ObjCPropertyDecl
  #{const CXCursor_ObjCIvarDecl} -> ObjCIvarDecl
  #{const CXCursor_ObjCInstanceMethodDecl} -> ObjCInstanceMethodDecl
  #{const CXCursor_ObjCClassMethodDecl} -> ObjCClassMethodDecl
  #{const CXCursor_ObjCImplementationDecl} -> ObjCImplementationDecl
  #{const CXCursor_ObjCCategoryImplDecl} -> ObjCCategoryImplDecl
  #{const CXCursor_TypedefDecl} -> TypedefDecl
  #{const CXCursor_CXXMethod} -> CXXMethod
  #{const CXCursor_Namespace} -> Namespace
  #{const CXCursor_LinkageSpec} -> LinkageSpec
  #{const CXCursor_Constructor} -> Constructor
  #{const CXCursor_Destructor} -> Destructor
  #{const CXCursor_ConversionFunction} -> ConversionFunction
  #{const CXCursor_TemplateTypeParameter} -> TemplateTypeParameter
  #{const CXCursor_NonTypeTemplateParameter} -> NonTypeTemplateParameter
  #{const CXCursor_TemplateTemplateParameter} -> TemplateTemplateParameter
  #{const CXCursor_FunctionTemplate} -> FunctionTemplate
  #{const CXCursor_ClassTemplate} -> ClassTemplate
  #{const CXCursor_ClassTemplatePartialSpecialization} -> ClassTemplatePartialSpecialization
  #{const CXCursor_NamespaceAlias} -> NamespaceAlias
  #{const CXCursor_UsingDirective} -> UsingDirective
  #{const CXCursor_UsingDeclaration} -> UsingDeclaration
  #{const CXCursor_TypeAliasDecl} -> TypeAliasDecl
  #{const CXCursor_ObjCSynthesizeDecl} -> ObjCSynthesizeDecl
  #{const CXCursor_ObjCDynamicDecl} -> ObjCDynamicDecl
  #{const CXCursor_CXXAccessSpecifier} -> CXXAccessSpecifier
  #{const CXCursor_FirstDecl} -> FirstDecl
  #{const CXCursor_LastDecl} -> LastDecl
  #{const CXCursor_FirstRef} -> FirstRef
  #{const CXCursor_ObjCSuperClassRef} -> ObjCSuperClassRef
  #{const CXCursor_ObjCProtocolRef} -> ObjCProtocolRef
  #{const CXCursor_ObjCClassRef} -> ObjCClassRef
  #{const CXCursor_TypeRef} -> TypeRef
  #{const CXCursor_CXXBaseSpecifier} -> CXXBaseSpecifier
  #{const CXCursor_TemplateRef} -> TemplateRef
  #{const CXCursor_NamespaceRef} -> NamespaceRef
  #{const CXCursor_MemberRef} -> MemberRef
  #{const CXCursor_LabelRef} -> LabelRef
  #{const CXCursor_OverloadedDeclRef} -> OverloadedDeclRef
  #{const CXCursor_VariableRef} -> VariableRef
  #{const CXCursor_LastRef} -> LastRef
  #{const CXCursor_FirstInvalid} -> FirstInvalid
  #{const CXCursor_InvalidFile} -> InvalidFile
  #{const CXCursor_NoDeclFound} -> NoDeclFound
  #{const CXCursor_NotImplemented} -> NotImplemented
  #{const CXCursor_InvalidCode} -> InvalidCode
  #{const CXCursor_LastInvalid} -> LastInvalid
  #{const CXCursor_FirstExpr} -> FirstExpr
  #{const CXCursor_UnexposedExpr} -> UnexposedExpr
  #{const CXCursor_DeclRefExpr} -> DeclRefExpr
  #{const CXCursor_MemberRefExpr} -> MemberRefExpr
  #{const CXCursor_CallExpr} -> CallExpr
  #{const CXCursor_ObjCMessageExpr} -> ObjCMessageExpr
  #{const CXCursor_BlockExpr} -> BlockExpr
  #{const CXCursor_IntegerLiteral} -> IntegerLiteral
  #{const CXCursor_FloatingLiteral} -> FloatingLiteral
  #{const CXCursor_ImaginaryLiteral} -> ImaginaryLiteral
  #{const CXCursor_StringLiteral} -> StringLiteral
  #{const CXCursor_CharacterLiteral} -> CharacterLiteral
  #{const CXCursor_ParenExpr} -> ParenExpr
  #{const CXCursor_UnaryOperator} -> UnaryOperator
  #{const CXCursor_ArraySubscriptExpr} -> ArraySubscriptExpr
  #{const CXCursor_BinaryOperator} -> BinaryOperator
  #{const CXCursor_CompoundAssignOperator} -> CompoundAssignOperator
  #{const CXCursor_ConditionalOperator} -> ConditionalOperator
  #{const CXCursor_CStyleCastExpr} -> CStyleCastExpr
  #{const CXCursor_CompoundLiteralExpr} -> CompoundLiteralExpr
  #{const CXCursor_InitListExpr} -> InitListExpr
  #{const CXCursor_AddrLabelExpr} -> AddrLabelExpr
  #{const CXCursor_StmtExpr} -> StmtExpr
  #{const CXCursor_GenericSelectionExpr} -> GenericSelectionExpr
  #{const CXCursor_GNUNullExpr} -> GNUNullExpr
  #{const CXCursor_CXXStaticCastExpr} -> CXXStaticCastExpr
  #{const CXCursor_CXXDynamicCastExpr} -> CXXDynamicCastExpr
  #{const CXCursor_CXXReinterpretCastExpr} -> CXXReinterpretCastExpr
  #{const CXCursor_CXXConstCastExpr} -> CXXConstCastExpr
  #{const CXCursor_CXXFunctionalCastExpr} -> CXXFunctionalCastExpr
  #{const CXCursor_CXXTypeidExpr} -> CXXTypeidExpr
  #{const CXCursor_CXXBoolLiteralExpr} -> CXXBoolLiteralExpr
  #{const CXCursor_CXXNullPtrLiteralExpr} -> CXXNullPtrLiteralExpr
  #{const CXCursor_CXXThisExpr} -> CXXThisExpr
  #{const CXCursor_CXXThrowExpr} -> CXXThrowExpr
  #{const CXCursor_CXXNewExpr} -> CXXNewExpr
  #{const CXCursor_CXXDeleteExpr} -> CXXDeleteExpr
  #{const CXCursor_UnaryExpr} -> UnaryExpr
  #{const CXCursor_ObjCStringLiteral} -> ObjCStringLiteral
  #{const CXCursor_ObjCEncodeExpr} -> ObjCEncodeExpr
  #{const CXCursor_ObjCSelectorExpr} -> ObjCSelectorExpr
  #{const CXCursor_ObjCProtocolExpr} -> ObjCProtocolExpr
  #{const CXCursor_ObjCBridgedCastExpr} -> ObjCBridgedCastExpr
  #{const CXCursor_PackExpansionExpr} -> PackExpansionExpr
  #{const CXCursor_SizeOfPackExpr} -> SizeOfPackExpr
  #{const CXCursor_LambdaExpr} -> LambdaExpr
  #{const CXCursor_ObjCBoolLiteralExpr} -> ObjCBoolLiteralExpr
  #{const CXCursor_ObjCSelfExpr} -> ObjCSelfExpr
  #{const CXCursor_LastExpr} -> LastExpr
  #{const CXCursor_FirstStmt} -> FirstStmt
  #{const CXCursor_UnexposedStmt} -> UnexposedStmt
  #{const CXCursor_LabelStmt} -> LabelStmt
  #{const CXCursor_CompoundStmt} -> CompoundStmt
  #{const CXCursor_CaseStmt} -> CaseStmt
  #{const CXCursor_DefaultStmt} -> DefaultStmt
  #{const CXCursor_IfStmt} -> IfStmt
  #{const CXCursor_SwitchStmt} -> SwitchStmt
  #{const CXCursor_WhileStmt} -> WhileStmt
  #{const CXCursor_DoStmt} -> DoStmt
  #{const CXCursor_ForStmt} -> ForStmt
  #{const CXCursor_GotoStmt} -> GotoStmt
  #{const CXCursor_IndirectGotoStmt} -> IndirectGotoStmt
  #{const CXCursor_ContinueStmt} -> ContinueStmt
  #{const CXCursor_BreakStmt} -> BreakStmt
  #{const CXCursor_ReturnStmt} -> ReturnStmt
  #{const CXCursor_GCCAsmStmt} -> GCCAsmStmt
  #{const CXCursor_AsmStmt} -> AsmStmt
  #{const CXCursor_ObjCAtTryStmt} -> ObjCAtTryStmt
  #{const CXCursor_ObjCAtCatchStmt} -> ObjCAtCatchStmt
  #{const CXCursor_ObjCAtFinallyStmt} -> ObjCAtFinallyStmt
  #{const CXCursor_ObjCAtThrowStmt} -> ObjCAtThrowStmt
  #{const CXCursor_ObjCAtSynchronizedStmt} -> ObjCAtSynchronizedStmt
  #{const CXCursor_ObjCAutoreleasePoolStmt} -> ObjCAutoreleasePoolStmt
  #{const CXCursor_ObjCForCollectionStmt} -> ObjCForCollectionStmt
  #{const CXCursor_CXXCatchStmt} -> CXXCatchStmt
  #{const CXCursor_CXXTryStmt} -> CXXTryStmt
  #{const CXCursor_CXXForRangeStmt} -> CXXForRangeStmt
  #{const CXCursor_SEHTryStmt} -> SEHTryStmt
  #{const CXCursor_SEHExceptStmt} -> SEHExceptStmt
  #{const CXCursor_SEHFinallyStmt} -> SEHFinallyStmt
  #{const CXCursor_MSAsmStmt} -> MSAsmStmt
  #{const CXCursor_NullStmt} -> NullStmt
  #{const CXCursor_DeclStmt} -> DeclStmt
  #{const CXCursor_OMPParallelDirective} -> OMPParallelDirective
  #{const CXCursor_OMPSimdDirective} -> OMPSimdDirective
  #{const CXCursor_OMPForDirective} -> OMPForDirective
  #{const CXCursor_OMPSectionsDirective} -> OMPSectionsDirective
  #{const CXCursor_OMPSectionDirective} -> OMPSectionDirective
  #{const CXCursor_OMPSingleDirective} -> OMPSingleDirective
  #{const CXCursor_OMPParallelForDirective} -> OMPParallelForDirective
  #{const CXCursor_OMPParallelSectionsDirective} -> OMPParallelSectionsDirective
  #{const CXCursor_OMPTaskDirective} -> OMPTaskDirective
  #{const CXCursor_OMPMasterDirective} -> OMPMasterDirective
  #{const CXCursor_OMPCriticalDirective} -> OMPCriticalDirective
  #{const CXCursor_OMPTaskyieldDirective} -> OMPTaskyieldDirective
  #{const CXCursor_OMPBarrierDirective} -> OMPBarrierDirective
  #{const CXCursor_OMPTaskwaitDirective} -> OMPTaskwaitDirective
  #{const CXCursor_OMPFlushDirective} -> OMPFlushDirective
  #{const CXCursor_SEHLeaveStmt} -> SEHLeaveStmt
  #{const CXCursor_LastStmt} -> LastStmt
  #{const CXCursor_TranslationUnit} -> TranslationUnit
  #{const CXCursor_FirstAttr} -> FirstAttr
  #{const CXCursor_UnexposedAttr} -> UnexposedAttr
  #{const CXCursor_IBActionAttr} -> IBActionAttr
  #{const CXCursor_IBOutletAttr} -> IBOutletAttr
  #{const CXCursor_IBOutletCollectionAttr} -> IBOutletCollectionAttr
  #{const CXCursor_CXXFinalAttr} -> CXXFinalAttr
  #{const CXCursor_CXXOverrideAttr} -> CXXOverrideAttr
  #{const CXCursor_AnnotateAttr} -> AnnotateAttr
  #{const CXCursor_AsmLabelAttr} -> AsmLabelAttr
  #{const CXCursor_PackedAttr} -> PackedAttr
  #{const CXCursor_PureAttr} -> PureAttr
  #{const CXCursor_ConstAttr} -> ConstAttr
  #{const CXCursor_NoDuplicateAttr} -> NoDuplicateAttr
  #{const CXCursor_CUDAConstantAttr} -> CUDAConstantAttr
  #{const CXCursor_CUDADeviceAttr} -> CUDADeviceAttr
  #{const CXCursor_CUDAGlobalAttr} -> CUDAGlobalAttr
  #{const CXCursor_CUDAHostAttr} -> CUDAHostAttr
  #{const CXCursor_LastAttr} -> LastAttr
  #{const CXCursor_PreprocessingDirective} -> PreprocessingDirective
  #{const CXCursor_MacroDefinition} -> MacroDefinition
  #{const CXCursor_MacroExpansion} -> MacroExpansion
  #{const CXCursor_MacroInstantiation} -> MacroInstantiation
  #{const CXCursor_InclusionDirective} -> InclusionDirective
  #{const CXCursor_FirstPreprocessing} -> FirstPreprocessing
  #{const CXCursor_LastPreprocessing} -> LastPreprocessing
  #{const CXCursor_ModuleImportDecl} -> ModuleImportDecl
  #{const CXCursor_FirstExtraDecl} -> FirstExtraDecl
  #{const CXCursor_LastExtraDecl} -> LastExtraDecl
  _ -> UnexposedDecl -- unrecognized enum value