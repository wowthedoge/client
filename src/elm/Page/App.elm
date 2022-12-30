port module Page.App exposing (Model, Msg, getTitle, init, isDirty, navKey, subscriptions, toGlobalData, toSession, update, view)

import Ant.Icons.Svg as AntIcons
import Browser.Dom exposing (Element)
import Browser.Navigation as Nav
import Bytes exposing (Bytes)
import Coders exposing (sortByEncoder)
import Doc.ContactForm as ContactForm
import Doc.Data as Data
import Doc.Fullscreen exposing (viewFullscreenButtons)
import Doc.HelpScreen as HelpScreen
import Doc.List as DocList exposing (Model(..))
import Doc.Metadata as Metadata
import Doc.Switcher
import Doc.TreeStructure exposing (defaultTree)
import Doc.TreeUtils exposing (getTree)
import Doc.UI as UI
import Doc.VideoViewer as VideoViewer
import File exposing (File)
import File.Download as Download
import File.Select as Select
import GlobalData exposing (GlobalData)
import Html exposing (Html, div, strong)
import Html.Attributes exposing (class, classList, height, id, style, width)
import Html.Events exposing (onClick)
import Html.Extra exposing (viewIf)
import Html.Lazy exposing (lazy5)
import Http
import Import.Bulk.UI as ImportModal
import Import.Incoming
import Import.Opml
import Import.Single
import Import.Text as ImportText
import Json.Decode as Json
import Json.Encode as Enc
import Outgoing exposing (Msg(..), send)
import Page.Doc exposing (Msg(..), ParentMsg(..), exitFullscreen, saveAndStopEditing, saveCardIfEditing)
import Page.Doc.Export as Export exposing (ExportFormat(..), ExportSelection(..), exportView, exportViewError)
import Page.Doc.Incoming as Incoming exposing (Msg(..))
import Page.Doc.Theme exposing (Theme(..), applyTheme)
import Page.Empty
import RandomId
import Route
import Session exposing (Session)
import Svg.Attributes
import Task
import Time
import Translation exposing (Language, TranslationId(..), langToString, tr)
import Types exposing (HeaderMenuState(..), OutsideData, SidebarMenuState(..), SidebarState(..), SortBy(..), TooltipPosition, Tree, ViewMode(..))
import Upgrade exposing (Msg(..))



-- MODEL


type alias Model =
    { loading : Bool
    , documentState : DocumentState
    , sidebarState : SidebarState
    , sidebarMenuState : SidebarMenuState
    , headerMenu : HeaderMenuState
    , exportSettings : ( ExportSelection, ExportFormat )
    , modalState : ModalState
    , fileSearchField : String -- TODO: not needed if switcher isn't open
    , tooltip : Maybe ( Element, TooltipPosition, TranslationId )
    , theme : Theme
    , navKey : Nav.Key
    }


type DocumentState
    = Empty GlobalData Session
    | Doc DocState


type alias DocState =
    { session : Session
    , docId : String
    , docModel : Page.Doc.Model
    , data : Data.Model
    , titleField : Maybe String
    }


toDocModel : Model -> Maybe Page.Doc.Model
toDocModel { documentState } =
    case documentState of
        Doc { docModel } ->
            Just docModel

        _ ->
            Nothing


toData : Model -> Maybe Data.Model
toData { documentState } =
    case documentState of
        Doc { data } ->
            Just data

        _ ->
            Nothing


type alias DbData =
    { dbName : String, isNew : Bool }


type ModalState
    = NoModal
    | FileSwitcher Doc.Switcher.Model
    | SidebarContextMenu String ( Float, Float )
    | TemplateSelector
    | HelpScreen
    | VideoViewer VideoViewer.Model
    | Wordcount Page.Doc.Model
    | ImportModal ImportModal.Model
    | ImportTextModal ImportText.Model
    | ContactForm ContactForm.Model
    | UpgradeModal


defaultModel : Nav.Key -> GlobalData -> Session -> Maybe ( String, Page.Doc.Model ) -> Model
defaultModel nKey globalData session docModel_ =
    { loading = True
    , documentState =
        case docModel_ of
            Just ( docId, docModel ) ->
                Doc
                    { session = session
                    , docId = docId
                    , docModel = docModel
                    , data = Data.empty
                    , titleField = Session.getDocName session docId
                    }

            Nothing ->
                Empty globalData session
    , sidebarState =
        if Session.fileMenuOpen session then
            File

        else
            SidebarClosed
    , sidebarMenuState = NoSidebarMenu
    , headerMenu = NoHeaderMenu
    , exportSettings = ( ExportEverything, DOCX )
    , modalState = NoModal
    , fileSearchField = ""
    , tooltip = Nothing
    , theme = Default
    , navKey = nKey
    }


init : Nav.Key -> GlobalData -> Session -> Maybe DbData -> ( Model, Cmd Msg )
init nKey globalData session dbData_ =
    case dbData_ of
        Just dbData ->
            if dbData.isNew then
                ( defaultModel nKey globalData session (Just ( dbData.dbName, Page.Doc.init True globalData ))
                , Cmd.batch
                    [ send <| InitDocument dbData.dbName
                    , Task.attempt (always NoOp) (Browser.Dom.focus "card-edit-1")
                    ]
                )

            else
                ( defaultModel nKey globalData session (Just ( dbData.dbName, Page.Doc.init False globalData ))
                , send <| LoadDocument dbData.dbName
                )

        Nothing ->
            case Session.lastDocId session of
                Just docId ->
                    ( defaultModel nKey globalData session Nothing, Route.replaceUrl nKey (Route.DocUntitled docId) )

                Nothing ->
                    ( defaultModel nKey globalData session Nothing, send <| GetDocumentList )


isDirty : Model -> Bool
isDirty model =
    case model.documentState of
        Doc { docModel } ->
            docModel.dirty

        Empty _ _ ->
            False


getTitle : Model -> Maybe String
getTitle model =
    case model.documentState of
        Doc { session, docId, docModel } ->
            Session.getDocName session docId

        Empty _ _ ->
            Nothing


toSession : Model -> Session
toSession { documentState } =
    case documentState of
        Doc { session, docModel } ->
            session

        Empty _ session ->
            session


navKey : Model -> Nav.Key
navKey model =
    model.navKey


toGlobalData : Model -> GlobalData
toGlobalData { documentState } =
    case documentState of
        Doc { docModel } ->
            docModel.globalData

        Empty gData _ ->
            gData


updateSession : Session -> Model -> Model
updateSession newSession ({ documentState } as model) =
    case documentState of
        Doc ({ docModel } as docState) ->
            { model | documentState = Doc { docState | session = newSession } }

        Empty globalData _ ->
            { model | documentState = Empty globalData newSession }


updateGlobalData : GlobalData -> Model -> Model
updateGlobalData newGlobalData ({ documentState } as model) =
    case documentState of
        Doc ({ docModel } as docState) ->
            { model | documentState = Doc { docState | docModel = { docModel | globalData = newGlobalData } } }

        Empty _ session ->
            { model | documentState = Empty newGlobalData session }



-- UPDATE


type Msg
    = NoOp
    | GotDocMsg Page.Doc.Msg
    | LoginStateChanged Session
    | TimeUpdate Time.Posix
    | SettingsChanged Json.Value
    | LogoutRequested
    | IncomingAppMsg AppMsg
    | IncomingDocMsg Incoming.Msg
    | LogErr String
      -- Sidebar
    | TemplateSelectorOpened
    | SortByChanged SortBy
    | SidebarStateChanged SidebarState
    | SidebarContextClicked String ( Float, Float )
    | DuplicateDoc String
    | DeleteDoc String
    | ReceivedDocuments DocList.Model
    | SwitcherOpened
    | SwitcherClosed
      -- HEADER: Title
    | TitleFocused
    | TitleFieldChanged String
    | TitleEdited
    | TitleEditCanceled
      -- HEADER: Settings
    | DocSettingsToggled Bool
    | ThemeChanged Theme
      -- HEADER: History
    | HistoryToggled Bool
    | CheckoutCommit String
    | Restore
    | CancelHistory
      -- HEADER: Export & Print
    | ExportPreviewToggled Bool
    | ExportSelectionChanged ExportSelection
    | ExportFormatChanged ExportFormat
    | Export
    | Exported String (Result Http.Error Bytes)
    | PrintRequested
      -- HELP Modal
    | ToggledHelpMenu Bool
    | ClickedShowVideos
    | VideoViewerOpened
    | VideoViewerMsg VideoViewer.Msg
    | ClickedShowWidget
    | ClickedEmailSupport
    | ContactFormMsg ContactForm.Model ContactForm.Msg
    | CopyEmailClicked Bool
    | ContactFormSubmitted ContactForm.Model
    | ContactFormSent (Result Http.Error ())
      -- Account menu
    | ToggledAccountMenu Bool
    | LanguageMenuRequested (Maybe String)
    | LanguageMenuReceived Element
    | LanguageChanged Language
      -- Import
    | ImportBulkClicked
    | ImportBulkCompleted
    | ImportTextClicked
    | ImportModalMsg ImportModal.Msg
    | ImportTextModalMsg ImportText.Msg
    | ImportTextLoaded ImportText.Settings (List String) (List String)
    | ImportTextIdGenerated Tree (Maybe String) String
    | ImportOpmlRequested
    | ImportOpmlSelected File
    | ImportOpmlLoaded String String
    | ImportOpmlIdGenerated Tree String String
    | ImportOpmlCompleted String
    | ImportJSONRequested
    | ImportJSONSelected File
    | ImportJSONLoaded String String
    | ImportJSONIdGenerated Tree String String
    | ImportJSONCompleted String
      -- FULLSCREEN mode
    | SaveChanges
    | SaveAndExitFullscreen
    | ExitFullscreenRequested
    | FullscreenRequested
      -- Misc UI
    | CloseEmailConfirmBanner
    | ToggledUpgradeModal Bool
    | UpgradeModalMsg Upgrade.Msg
    | ToggledShortcutTray
    | WordcountModalOpened
    | FileSearchChanged String
    | TooltipRequested String TooltipPosition TranslationId
    | TooltipReceived Element TooltipPosition TranslationId
    | TooltipClosed
    | EmptyMessage
    | ModalClosed


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        session =
            toSession model

        globalData =
            toGlobalData model
    in
    case msg of
        NoOp ->
            ( model, Cmd.none )

        GotDocMsg docMsg ->
            case model.documentState of
                Doc ({ docModel } as docState) ->
                    let
                        ( newDocModel, newCmd, parentMsg ) =
                            Page.Doc.update docMsg docModel
                                |> (\( m, c, p ) -> ( m, Cmd.map GotDocMsg c, p ))
                    in
                    case parentMsg of
                        CloseTooltip ->
                            ( { model | documentState = Doc { docState | docModel = newDocModel }, tooltip = Nothing }, newCmd )

                        CommitDo commitTime ->
                            ( { model | documentState = Doc { docState | docModel = newDocModel } }, newCmd )
                                |> addToHistoryDo

                        LocalSaveDo saveTime ->
                            ( { model | documentState = Doc { docState | docModel = newDocModel } }, newCmd )

                        NoParentMsg ->
                            ( { model | documentState = Doc { docState | docModel = newDocModel } }, newCmd )

                Empty _ _ ->
                    ( model, Cmd.none )

        LoginStateChanged newSession ->
            ( model |> updateSession newSession, Route.pushUrl model.navKey Route.Login )

        TimeUpdate time ->
            ( model |> updateGlobalData (GlobalData.updateTime time globalData)
            , Cmd.none
            )

        SettingsChanged json ->
            ( model |> updateSession (Session.sync json (GlobalData.currentTime globalData) session), Cmd.none )

        LogoutRequested ->
            ( model, Session.logout )

        IncomingAppMsg appMsg ->
            ( model, Cmd.none )

        IncomingDocMsg incomingMsg ->
            let
                doNothing =
                    ( model, Cmd.none )

                passThroughTo docState =
                    Page.Doc.incoming incomingMsg docState.docModel
                        |> (\( d, c ) ->
                                ( { model | documentState = Doc { docState | docModel = d } }, Cmd.map GotDocMsg c )
                           )
            in
            case ( incomingMsg, model.documentState ) of
                ( Keyboard shortcut, Doc ({ docId, docModel } as docState) ) ->
                    case model.modalState of
                        FileSwitcher switcherModel ->
                            case shortcut of
                                "enter" ->
                                    case switcherModel.selectedDocument of
                                        Just selectedDocId ->
                                            ( model, Route.pushUrl model.navKey (Route.DocUntitled selectedDocId) )

                                        Nothing ->
                                            ( model, Cmd.none )

                                "down" ->
                                    ( { model | modalState = FileSwitcher (Doc.Switcher.down switcherModel) }, Cmd.none )

                                "up" ->
                                    ( { model | modalState = FileSwitcher (Doc.Switcher.up switcherModel) }, Cmd.none )

                                "mod+o" ->
                                    ( { model | modalState = NoModal }, Cmd.none )

                                "esc" ->
                                    ( { model | fileSearchField = "", modalState = NoModal }, Cmd.none )

                                _ ->
                                    ( model, Cmd.none )

                        Wordcount _ ->
                            case shortcut of
                                "w" ->
                                    ( { model | modalState = NoModal }, Cmd.none )

                                "mod+o" ->
                                    normalMode docModel
                                        (model |> openSwitcher docId docModel)
                                        (passThroughTo docState)

                                "esc" ->
                                    ( { model | modalState = NoModal }, Cmd.none )

                                _ ->
                                    ( model, Cmd.none )

                        HelpScreen ->
                            case shortcut of
                                "?" ->
                                    ( { model | modalState = NoModal }, Cmd.none )

                                "mod+o" ->
                                    normalMode docModel
                                        (model |> openSwitcher docId docModel)
                                        (passThroughTo docState)

                                "esc" ->
                                    ( { model | modalState = NoModal }, Cmd.none )

                                _ ->
                                    ( model, Cmd.none )

                        NoModal ->
                            case shortcut of
                                "w" ->
                                    normalMode docModel
                                        ( { model | modalState = Wordcount docModel }, Cmd.none )
                                        (passThroughTo docState)

                                "?" ->
                                    normalMode docModel
                                        ( { model | modalState = HelpScreen }, Cmd.none )
                                        (passThroughTo docState)

                                "mod+o" ->
                                    normalMode docModel
                                        (model |> openSwitcher docId docModel)
                                        (passThroughTo docState)

                                "mod+z" ->
                                    normalMode docModel
                                        (toggleHistory True -1 model)
                                        (passThroughTo docState)

                                "mod+shift+z" ->
                                    normalMode docModel
                                        (toggleHistory True 1 model)
                                        (passThroughTo docState)

                                _ ->
                                    passThroughTo docState

                        _ ->
                            case shortcut of
                                "esc" ->
                                    ( { model | modalState = NoModal }, Cmd.none )

                                "mod+o" ->
                                    normalMode docModel
                                        (model |> openSwitcher docId docModel)
                                        (passThroughTo docState)

                                _ ->
                                    passThroughTo docState

                ( TestTextImportLoaded files, _ ) ->
                    case model.modalState of
                        ImportTextModal modalState ->
                            ( { model | modalState = ImportText.setFileList files modalState |> ImportTextModal }
                            , Cmd.none
                            )

                        _ ->
                            doNothing

                ( WillPrint, Doc _ ) ->
                    ( { model | headerMenu = ExportPreview }, Cmd.none )

                ( _, Doc docState ) ->
                    passThroughTo docState

                _ ->
                    doNothing

        LogErr err ->
            ( model
            , send (ConsoleLogRequested err)
            )

        -- Sidebar
        TemplateSelectorOpened ->
            ( { model | modalState = TemplateSelector }, Cmd.none )

        SortByChanged newSort ->
            let
                newSession =
                    Session.setSortBy newSort session
            in
            ( model |> updateSession newSession, send <| SaveUserSetting ( "sortBy", sortByEncoder newSort ) )

        SidebarStateChanged newSidebarState ->
            let
                ( newSessionData, maybeSaveSidebarState ) =
                    case newSidebarState of
                        File ->
                            ( Session.setFileOpen True session, send <| SetSidebarState True )

                        _ ->
                            ( Session.setFileOpen True session, send <| SetSidebarState False )

                newDropdownState =
                    case ( newSidebarState, model.sidebarMenuState ) of
                        ( File, Account _ ) ->
                            NoSidebarMenu

                        ( _, _ ) ->
                            model.sidebarMenuState
            in
            ( { model
                | sidebarState = newSidebarState
                , tooltip = Nothing
                , sidebarMenuState = newDropdownState
              }
                |> updateSession newSessionData
            , maybeSaveSidebarState
            )

        SidebarContextClicked docId ( x, y ) ->
            ( { model | modalState = SidebarContextMenu docId ( x, y ) }, Cmd.none )

        DuplicateDoc docId ->
            ( { model | modalState = NoModal }, Route.replaceUrl model.navKey (Route.Copy docId) )

        DeleteDoc docId ->
            let
                docName_ =
                    Session.getDocName session docId
            in
            ( { model | modalState = NoModal }, send <| RequestDelete docId docName_ )

        ReceivedDocuments newListState ->
            let
                newSession =
                    Session.updateDocuments newListState session

                ( routeCmd, isLoading ) =
                    case ( model.documentState, Session.documents newSession ) of
                        ( Doc { docId, docModel }, Success docList ) ->
                            ( docList
                                |> List.map (\d -> Metadata.getDocId d == docId)
                                |> List.any identity
                                |> (\docStillExists ->
                                        if docStillExists then
                                            Cmd.none

                                        else
                                            Route.replaceUrl model.navKey Route.Root
                                   )
                            , True
                            )

                        ( Empty _ _, Success [] ) ->
                            ( Cmd.none, False )

                        ( Empty _ _, Success docList ) ->
                            ( DocList.getLastUpdated (Success docList)
                                |> Maybe.map (\s -> Route.replaceUrl model.navKey (Route.DocUntitled s))
                                |> Maybe.withDefault Cmd.none
                            , True
                            )

                        _ ->
                            ( Cmd.none, True )
            in
            ( { model | loading = isLoading } |> updateSession newSession, routeCmd )

        SwitcherOpened ->
            case model.documentState of
                Doc { docId, docModel } ->
                    openSwitcher docId docModel model

                Empty _ _ ->
                    ( model, Cmd.none )

        SwitcherClosed ->
            closeSwitcher model

        -- Header
        TitleFocused ->
            case model.documentState of
                Doc { titleField } ->
                    case titleField of
                        Nothing ->
                            ( model, send <| SelectAll "title-rename" )

                        Just _ ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        TitleFieldChanged newTitle ->
            case model.documentState of
                Doc ({ titleField } as docState) ->
                    ( { model | documentState = Doc { docState | titleField = Just newTitle } }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        TitleEdited ->
            case model.documentState of
                Doc { titleField, docModel, docId } ->
                    case titleField of
                        Just editedTitle ->
                            if String.trim editedTitle == "" then
                                ( model, Cmd.batch [ send <| Alert "Title cannot be blank", Task.attempt (always NoOp) (Browser.Dom.focus "title-rename") ] )

                            else if Just editedTitle /= Session.getDocName session docId then
                                ( model, Cmd.batch [ send <| RenameDocument editedTitle, Task.attempt (always NoOp) (Browser.Dom.blur "title-rename") ] )

                            else
                                ( model, Cmd.none )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        TitleEditCanceled ->
            case model.documentState of
                Doc ({ docModel, docId } as docState) ->
                    ( { model | documentState = Doc { docState | titleField = Session.getDocName session docId } }
                    , Task.attempt (always NoOp) (Browser.Dom.blur "title-rename")
                    )

                _ ->
                    ( model, Cmd.none )

        HistoryToggled isOpen ->
            model |> toggleHistory isOpen 0

        CheckoutCommit commitSha ->
            case ( model.headerMenu, model.documentState ) of
                ( HistoryView historyState, Doc docState ) ->
                    let
                        newTree =
                            Data.checkout commitSha docState.data
                    in
                    ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        Restore ->
            ( { model | headerMenu = NoHeaderMenu }
            , Cmd.none
            )

        -- TODO: |> localSaveDo
        -- TODO: |> addToHistoryDo
        CancelHistory ->
            case model.headerMenu of
                HistoryView historyState ->
                    ( { model | headerMenu = NoHeaderMenu }
                    , Cmd.none
                    )

                -- TODO: |> checkoutCommit historyState.start
                _ ->
                    ( model
                    , Cmd.none
                    )

        Export ->
            case model.documentState of
                Doc { docId, docModel } ->
                    let
                        vs =
                            docModel.viewState

                        activeTree =
                            getTree vs.active docModel.workingTree.tree
                                |> Maybe.withDefault docModel.workingTree.tree
                    in
                    ( model
                    , Export.command
                        Exported
                        docId
                        (Session.getDocName session docId |> Maybe.withDefault "Untitled")
                        model.exportSettings
                        activeTree
                        docModel.workingTree.tree
                    )

                _ ->
                    ( model, Cmd.none )

        Exported docName (Ok bytes) ->
            let
                mime =
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

                filename =
                    docName ++ ".docx"
            in
            ( model, Download.bytes filename mime bytes )

        Exported _ (Err _) ->
            ( model, Cmd.none )

        PrintRequested ->
            ( model, send <| Print )

        DocSettingsToggled isOpen ->
            ( { model
                | headerMenu =
                    if isOpen then
                        Settings

                    else
                        NoHeaderMenu
              }
            , Cmd.none
            )

        ThemeChanged newTheme ->
            ( { model | theme = newTheme }, send <| SaveThemeSetting newTheme )

        ExportPreviewToggled previewEnabled ->
            ( { model
                | headerMenu =
                    if previewEnabled then
                        ExportPreview

                    else
                        NoHeaderMenu
              }
            , Cmd.none
            )

        -- TODO: |> activate vs.active True
        ExportSelectionChanged expSel ->
            ( { model | exportSettings = Tuple.mapFirst (always expSel) model.exportSettings }, Cmd.none )

        ExportFormatChanged expFormat ->
            ( { model | exportSettings = Tuple.mapSecond (always expFormat) model.exportSettings }, Cmd.none )

        -- HELP Modal
        ToggledHelpMenu isOpen ->
            ( { model | modalState = HelpScreen }, Cmd.none )

        ClickedShowVideos ->
            ( { model | modalState = VideoViewer VideoViewer.init, sidebarMenuState = NoSidebarMenu }, Cmd.none )

        VideoViewerOpened ->
            ( { model | modalState = VideoViewer VideoViewer.init }, Cmd.none )

        VideoViewerMsg videoViewerMsg ->
            ( { model | modalState = VideoViewer (VideoViewer.update videoViewerMsg) }, Cmd.none )

        ClickedShowWidget ->
            ( { model | modalState = NoModal }, send <| ShowWidget )

        ClickedEmailSupport ->
            let
                fromEmail =
                    Session.name session
                        |> Maybe.withDefault ""
            in
            ( { model | modalState = ContactForm (ContactForm.init fromEmail), sidebarMenuState = NoSidebarMenu }
            , Task.attempt (\_ -> NoOp) (Browser.Dom.focus "contact-body")
            )

        ContactFormMsg formModel formMsg ->
            ( { model | modalState = ContactForm (ContactForm.update formMsg formModel) }, Cmd.none )

        CopyEmailClicked isUrgent ->
            if isUrgent then
                ( model, send <| CopyToClipboard "{%SUPPORT_URGENT_EMAIL%}" "#email-copy-btn" )

            else
                ( model, send <| CopyToClipboard "{%SUPPORT_EMAIL%}" "#email-copy-btn" )

        ContactFormSubmitted formModel ->
            ( model, ContactForm.send ContactFormSent formModel )

        ContactFormSent res ->
            case res of
                Ok _ ->
                    ( { model | modalState = NoModal }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        -- Account menu TODO
        ToggledAccountMenu isOpen ->
            let
                ( newDropdownState, newSidebarState ) =
                    if isOpen then
                        ( Account Nothing, SidebarClosed )

                    else
                        ( NoSidebarMenu, model.sidebarState )
            in
            ( { model
                | sidebarMenuState = newDropdownState
                , sidebarState = newSidebarState
                , tooltip = Nothing
              }
            , Cmd.none
            )

        LanguageMenuRequested elId_ ->
            case ( elId_, model.sidebarMenuState ) of
                ( Just elId, Account _ ) ->
                    ( model
                    , Browser.Dom.getElement elId
                        |> Task.attempt
                            (\result ->
                                case result of
                                    Ok el ->
                                        LanguageMenuReceived el

                                    Err _ ->
                                        NoOp
                            )
                    )

                _ ->
                    ( { model | sidebarMenuState = Account Nothing }, Cmd.none )

        LanguageMenuReceived el ->
            ( { model | sidebarMenuState = Account (Just el) }, Cmd.none )

        LanguageChanged newLang ->
            if newLang /= GlobalData.language globalData then
                ( { model
                    | sidebarMenuState = NoSidebarMenu
                  }
                    |> updateGlobalData (GlobalData.setLanguage newLang globalData)
                , send <| SaveUserSetting ( "language", langToString newLang |> Enc.string )
                )

            else
                ( model, Cmd.none )

        -- Import
        ImportBulkClicked ->
            ( { model | modalState = ImportModal (ImportModal.init session) }, Cmd.none )

        ImportBulkCompleted ->
            ( { model | modalState = NoModal }, Cmd.none )

        ImportTextClicked ->
            ( { model | modalState = ImportTextModal ImportText.init }, Cmd.none )

        ImportModalMsg modalMsg ->
            case model.modalState of
                ImportModal importModal ->
                    let
                        ( newModalState, newCmd ) =
                            ImportModal.update modalMsg importModal
                                |> Tuple.mapBoth ImportModal (Cmd.map ImportModalMsg)
                    in
                    ( { model | modalState = newModalState }, newCmd )

                _ ->
                    ( model, Cmd.none )

        ImportTextModalMsg modalMsg ->
            case model.modalState of
                ImportTextModal modalModel ->
                    let
                        u =
                            ImportText.update modalMsg modalModel

                        newCmd =
                            Cmd.batch
                                ([ Cmd.map ImportTextModalMsg u.cmd ]
                                    ++ (if u.sendTestHack then
                                            [ send <| IntegrationTestEvent "ImportTextRequested" ]

                                        else
                                            []
                                       )
                                    ++ (case u.importRequested of
                                            Just ( files, importSettings ) ->
                                                let
                                                    tasks =
                                                        files |> List.map File.toString |> Task.sequence

                                                    metadata =
                                                        files |> List.map File.name
                                                in
                                                [ Task.perform (ImportTextLoaded importSettings metadata) tasks ]

                                            Nothing ->
                                                []
                                       )
                                )
                    in
                    ( { model | modalState = ImportTextModal u.model }, newCmd )

                _ ->
                    ( model, Cmd.none )

        ImportTextLoaded settings metadata markdownStrings ->
            let
                ( importedTree, newSeed, newTitle_ ) =
                    ImportText.toTree (GlobalData.seed globalData) metadata markdownStrings settings

                newGlobalData =
                    GlobalData.setSeed newSeed globalData
            in
            ( { model | loading = True } |> updateGlobalData newGlobalData
            , RandomId.generate (ImportTextIdGenerated importedTree newTitle_)
            )

        ImportTextIdGenerated tree newTitle_ docId ->
            let
                author =
                    session |> Session.name |> Maybe.withDefault "jane.doe@gmail.com"

                encodeMaybeRename =
                    newTitle_
                        |> Maybe.map (\title -> Metadata.renameAndEncode title)
                        |> Maybe.withDefault Metadata.encode

                commitReq_ =
                    Data.requestCommit tree author Data.empty (Metadata.new docId |> encodeMaybeRename)
            in
            case commitReq_ of
                Just commitReq ->
                    ( model, send <| SaveImportedData commitReq )

                Nothing ->
                    ( model, Cmd.none )

        ImportOpmlRequested ->
            ( model, Select.file [ "application/xml", "text/xml", "text/x-opml", ".opml" ] ImportOpmlSelected )

        ImportOpmlSelected file ->
            ( model, Task.perform (ImportOpmlLoaded (File.name file)) (File.toString file) )

        ImportOpmlLoaded fileName opmlString ->
            let
                ( importTreeResult, newSeed ) =
                    Import.Opml.treeResult (GlobalData.seed globalData) opmlString

                newGlobalData =
                    GlobalData.setSeed newSeed globalData
            in
            case importTreeResult of
                Ok tree ->
                    ( { model | loading = True } |> updateGlobalData newGlobalData
                    , RandomId.generate (ImportOpmlIdGenerated tree fileName)
                    )

                Err err ->
                    ( model |> updateGlobalData newGlobalData, Cmd.none )

        ImportOpmlIdGenerated tree fileName docId ->
            let
                author =
                    session |> Session.name |> Maybe.withDefault "jane.doe@gmail.com"

                commitReq_ =
                    Data.requestCommit tree author Data.empty (Metadata.new docId |> Metadata.renameAndEncode fileName)
            in
            case commitReq_ of
                Just commitReq ->
                    ( model, send <| SaveImportedData commitReq )

                Nothing ->
                    ( model, Cmd.none )

        ImportOpmlCompleted docId ->
            ( model, Route.pushUrl model.navKey (Route.DocUntitled docId) )

        ImportJSONRequested ->
            ( model, Select.file [ "application/json", "text/plain" ] ImportJSONSelected )

        ImportJSONSelected file ->
            ( model, Task.perform (ImportJSONLoaded (File.name file)) (File.toString file) )

        ImportJSONLoaded fileName jsonString ->
            let
                ( importTreeDecoder, newSeed ) =
                    Import.Single.decoder (GlobalData.seed globalData)

                newGlobalData =
                    GlobalData.setSeed newSeed globalData
            in
            case Json.decodeString importTreeDecoder jsonString of
                Ok tree ->
                    ( { model | loading = True } |> updateGlobalData newGlobalData
                    , RandomId.generate (ImportJSONIdGenerated tree fileName)
                    )

                Err err ->
                    ( model |> updateGlobalData newGlobalData, Cmd.none )

        ImportJSONIdGenerated tree fileName docId ->
            let
                author =
                    session |> Session.name |> Maybe.withDefault "jane.doe@gmail.com"

                commitReq_ =
                    Data.requestCommit tree author Data.empty (Metadata.new docId |> Metadata.renameAndEncode fileName)
            in
            case commitReq_ of
                Just commitReq ->
                    ( model, send <| SaveImportedData commitReq )

                Nothing ->
                    ( model, Cmd.none )

        ImportJSONCompleted docId ->
            ( model, Route.pushUrl model.navKey (Route.DocUntitled docId) )

        -- FULLSCREEN mode
        ExitFullscreenRequested ->
            case model.documentState of
                Doc docState ->
                    let
                        ( newDocModel, newDocCmd ) =
                            docState.docModel
                                |> exitFullscreen
                    in
                    ( { model | documentState = Doc { docState | docModel = newDocModel } }, Cmd.map GotDocMsg newDocCmd )

                _ ->
                    ( model, Cmd.none )

        SaveChanges ->
            case model.documentState of
                Doc docState ->
                    let
                        ( newDocModel, newDocCmd ) =
                            ( docState.docModel, Cmd.none )
                                |> saveCardIfEditing
                    in
                    ( { model | documentState = Doc { docState | docModel = newDocModel } }, Cmd.map GotDocMsg newDocCmd )

                _ ->
                    ( model, Cmd.none )

        SaveAndExitFullscreen ->
            case model.documentState of
                Doc docState ->
                    let
                        ( newDocModel, newDocCmd ) =
                            docState.docModel
                                |> saveAndStopEditing
                    in
                    ( { model | documentState = Doc { docState | docModel = newDocModel } }, Cmd.map GotDocMsg newDocCmd )

                _ ->
                    ( model, Cmd.none )

        FullscreenRequested ->
            -- TODO:
            ( model, Cmd.none )

        -- Misc UI
        CloseEmailConfirmBanner ->
            ( model |> updateSession (Session.confirmEmail (GlobalData.currentTime globalData) session), Cmd.none )

        ToggledUpgradeModal isOpen ->
            ( { model
                | modalState =
                    if isOpen then
                        UpgradeModal

                    else
                        NoModal
                , sidebarMenuState = NoSidebarMenu
              }
            , Cmd.none
            )

        UpgradeModalMsg upgradeModalMsg ->
            case upgradeModalMsg of
                UpgradeModalClosed ->
                    ( { model | modalState = NoModal }, Cmd.none )

                CheckoutClicked checkoutData ->
                    case Session.name session of
                        Just email ->
                            let
                                data =
                                    Upgrade.toValue email checkoutData
                            in
                            ( model, send <| CheckoutButtonClicked data )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    let
                        newSession =
                            Session.updateUpgrade upgradeModalMsg session

                        maybeFlash =
                            case upgradeModalMsg of
                                PlanChanged _ ->
                                    send <| FlashPrice

                                _ ->
                                    Cmd.none
                    in
                    ( model |> updateSession newSession, maybeFlash )

        ToggledShortcutTray ->
            let
                newIsOpen =
                    not <| Session.shortcutTrayOpen session

                newSession =
                    Session.setShortcutTrayOpen newIsOpen session
            in
            ( { model
                | headerMenu =
                    if model.headerMenu == ExportPreview && newIsOpen then
                        NoHeaderMenu

                    else
                        model.headerMenu
                , tooltip = Nothing
              }
                |> updateSession newSession
            , send <| SaveUserSetting ( "shortcutTrayOpen", Enc.bool newIsOpen )
            )

        WordcountModalOpened ->
            case model.documentState of
                Doc { docModel } ->
                    ( { model
                        | modalState = Wordcount docModel
                        , headerMenu = NoHeaderMenu
                      }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        FileSearchChanged term ->
            let
                updatedModal =
                    case model.modalState of
                        FileSwitcher switcherModel ->
                            FileSwitcher (Doc.Switcher.search term switcherModel)

                        _ ->
                            model.modalState
            in
            ( { model | fileSearchField = term, modalState = updatedModal }, Cmd.none )

        TooltipRequested elId tipPos content ->
            ( model
            , Browser.Dom.getElement elId
                |> Task.attempt
                    (\result ->
                        case result of
                            Ok el ->
                                TooltipReceived el tipPos content

                            Err _ ->
                                NoOp
                    )
            )

        TooltipReceived el tipPos content ->
            ( { model | tooltip = Just ( el, tipPos, content ) }, Cmd.none )

        TooltipClosed ->
            ( { model | tooltip = Nothing }, Cmd.none )

        EmptyMessage ->
            ( model, send <| EmptyMessageShown )

        ModalClosed ->
            case model.modalState of
                VideoViewer _ ->
                    ( { model | modalState = HelpScreen }, Cmd.none )

                ContactForm _ ->
                    ( { model | modalState = HelpScreen }, Cmd.none )

                _ ->
                    ( { model | modalState = NoModal }, Cmd.none )


addToHistoryDo : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
addToHistoryDo ( model, prevCmd ) =
    case model.documentState of
        Doc { session, docModel, docId, data } ->
            let
                author =
                    session |> Session.name |> Maybe.withDefault "unknown" |> (\a -> "<" ++ a ++ ">")

                metadata =
                    Session.getMetadata session docId
                        |> Maybe.withDefault (Metadata.new docId)

                commitReq_ =
                    Data.requestCommit docModel.workingTree.tree author data (Metadata.encode metadata)
            in
            case commitReq_ of
                Just commitReq ->
                    ( model
                    , Cmd.batch
                        [ send <| CommitData commitReq
                        , prevCmd
                        ]
                    )

                Nothing ->
                    ( model, prevCmd )

        Empty _ _ ->
            ( model, prevCmd )


normalMode : Page.Doc.Model -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
normalMode docModel modified noOp =
    if docModel.viewState.viewMode == Normal then
        modified

    else
        noOp


openSwitcher : String -> Page.Doc.Model -> Model -> ( Model, Cmd Msg )
openSwitcher docId docModel model =
    let
        metadata_ =
            Session.getMetadata (toSession model) docId
    in
    case metadata_ of
        Just currentMetadata ->
            ( { model
                | modalState =
                    FileSwitcher
                        { currentDocument = currentMetadata
                        , selectedDocument = Just docId
                        , searchField = ""
                        , docList = Session.documents (toSession model)
                        }
              }
            , Task.attempt (\_ -> NoOp) (Browser.Dom.focus "switcher-input")
            )

        Nothing ->
            ( model, Cmd.none )


closeSwitcher : Model -> ( Model, Cmd Msg )
closeSwitcher model =
    ( { model | modalState = NoModal }, Cmd.none )


toggleHistory : Bool -> Int -> Model -> ( Model, Cmd msg )
toggleHistory isOpen delta model =
    case ( isOpen, model |> toData |> Maybe.andThen (\d -> Data.head "heads/master" d) ) of
        ( True, Just refObj ) ->
            ( { model | headerMenu = HistoryView { start = refObj.value, currentView = refObj.value } }, send <| HistorySlider delta )

        _ ->
            ( { model | headerMenu = NoHeaderMenu }, Cmd.none )



-- Translation Helper Function


text : Language -> TranslationId -> Html msg
text lang tid =
    Html.text <| tr lang tid


textNoTr : String -> Html msg
textNoTr str =
    Html.text str


emptyText : Html msg
emptyText =
    Html.text ""



-- VIEW


view : Model -> Html Msg
view ({ documentState } as model) =
    let
        session =
            toSession model

        lang =
            GlobalData.language (toGlobalData model)

        email =
            Session.name session
                |> Maybe.withDefault "<email error>"

        viewTooltip =
            case model.tooltip of
                Just tooltip ->
                    UI.viewTooltip lang tooltip

                Nothing ->
                    emptyText

        sidebarMsgs =
            { sidebarStateChanged = SidebarStateChanged
            , noOp = NoOp
            , clickedNew = TemplateSelectorOpened
            , tooltipRequested = TooltipRequested
            , tooltipClosed = TooltipClosed
            , clickedSwitcher = SwitcherOpened
            , clickedHelp = ToggledHelpMenu True
            , clickedEmailSupport = ClickedEmailSupport
            , clickedShowVideos = ClickedShowVideos
            , languageMenuRequested = LanguageMenuRequested
            , logout = LogoutRequested
            , toggledAccount = ToggledAccountMenu
            , upgrade = ToggledUpgradeModal True
            , fileSearchChanged = FileSearchChanged
            , changeSortBy = SortByChanged
            , contextMenuOpened = SidebarContextClicked
            , languageChanged = LanguageChanged
            , fullscreenRequested = FullscreenRequested
            }
    in
    case documentState of
        Doc { docModel, data, titleField, docId } ->
            let
                activeTree_ =
                    getTree docModel.viewState.active docModel.workingTree.tree

                exportViewOk =
                    lazy5 exportView
                        { export = Export
                        , printRequested = PrintRequested
                        , tooltipRequested = TooltipRequested
                        , tooltipClosed = TooltipClosed
                        }
                        (Session.getDocName session docId |> Maybe.withDefault "Untitled")
                        model.exportSettings

                maybeExportView =
                    case ( model.headerMenu, activeTree_, model.exportSettings ) of
                        ( ExportPreview, Just activeTree, _ ) ->
                            exportViewOk activeTree docModel.workingTree.tree

                        ( ExportPreview, Nothing, ( ExportEverything, _ ) ) ->
                            exportViewOk defaultTree docModel.workingTree.tree

                        ( ExportPreview, Nothing, _ ) ->
                            exportViewError "No card selected, cannot preview document"

                        _ ->
                            textNoTr ""

                maybeFullscreenButtons =
                    case docModel.viewState.viewMode of
                        FullscreenEditing ->
                            viewFullscreenButtons
                                { exitFullscreenRequested = ExitFullscreenRequested
                                , saveChanges = SaveChanges
                                , saveAndExitFullscreen = SaveAndExitFullscreen
                                }
                                { language = lang
                                , isMac = GlobalData.isMac (toGlobalData model)
                                , dirty = docModel.dirty
                                , model = docModel.workingTree
                                , lastLocalSave = docModel.lastLocalSave
                                , lastRemoteSave = docModel.lastRemoteSave
                                , currentTime = GlobalData.currentTime docModel.globalData
                                }

                        _ ->
                            textNoTr ""
            in
            div [ id "app-root", classList [ ( "loading", model.loading ) ], applyTheme model.theme ]
                (Page.Doc.view
                    { docMsg = GotDocMsg
                    , keyboard = \s -> IncomingDocMsg (Keyboard s)
                    , tooltipRequested = TooltipRequested
                    , tooltipClosed = TooltipClosed
                    }
                    docModel
                    ++ [ UI.viewHeader
                            { noOp = NoOp
                            , titleFocused = TitleFocused
                            , titleFieldChanged = TitleFieldChanged
                            , titleEdited = TitleEdited
                            , titleEditCanceled = TitleEditCanceled
                            , tooltipRequested = TooltipRequested
                            , tooltipClosed = TooltipClosed
                            , toggledHistory = HistoryToggled
                            , checkoutCommit = CheckoutCommit
                            , restore = Restore
                            , cancelHistory = CancelHistory
                            , toggledDocSettings = DocSettingsToggled (not <| model.headerMenu == Settings)
                            , wordCountClicked = WordcountModalOpened
                            , themeChanged = ThemeChanged
                            , toggledExport = ExportPreviewToggled (not <| model.headerMenu == ExportPreview)
                            , exportSelectionChanged = ExportSelectionChanged
                            , exportFormatChanged = ExportFormatChanged
                            , export = Export
                            , printRequested = PrintRequested
                            , toggledUpgradeModal = ToggledUpgradeModal
                            }
                            session
                            (Session.getDocName session docId)
                            model
                            data
                            docModel
                            titleField
                       , maybeExportView
                       , maybeFullscreenButtons
                       , UI.viewSidebar docModel.globalData
                            session
                            sidebarMsgs
                            docId
                            (Session.sortBy session)
                            model.fileSearchField
                            (Session.documents session)
                            (Session.name session |> Maybe.withDefault "" {- TODO -})
                            Nothing
                            model.sidebarMenuState
                            model.sidebarState
                       , viewIf (Session.isNotConfirmed session) (viewConfirmBanner lang CloseEmailConfirmBanner email)
                       , viewTooltip
                       ]
                    ++ UI.viewShortcuts
                        { toggledShortcutTray = ToggledShortcutTray
                        , tooltipRequested = TooltipRequested
                        , tooltipClosed = TooltipClosed
                        }
                        lang
                        (Session.shortcutTrayOpen session)
                        (GlobalData.isMac docModel.globalData)
                        docModel.workingTree.tree.children
                        docModel.textCursorInfo
                        docModel.viewState
                    ++ viewModal docModel.globalData session model.modalState
                )

        Empty globalData _ ->
            if model.loading then
                UI.viewAppLoadingSpinner (Session.fileMenuOpen session)

            else
                div [ id "app-root", classList [ ( "loading", model.loading ) ] ]
                    (Page.Empty.view { newClicked = TemplateSelectorOpened, emptyMessage = EmptyMessage }
                        ++ [ UI.viewSidebar globalData
                                session
                                sidebarMsgs
                                ""
                                ModifiedAt
                                ""
                                (Session.documents session)
                                (Session.name session |> Maybe.withDefault "" {- TODO -})
                                Nothing
                                model.sidebarMenuState
                                model.sidebarState
                           , viewIf (Session.isNotConfirmed session) (viewConfirmBanner lang CloseEmailConfirmBanner email)
                           , viewTooltip
                           ]
                        ++ viewModal globalData session model.modalState
                    )


viewModal : GlobalData -> Session -> ModalState -> List (Html Msg)
viewModal globalData session modalState =
    let
        language =
            GlobalData.language globalData
    in
    case modalState of
        NoModal ->
            [ emptyText ]

        FileSwitcher switcherModel ->
            Doc.Switcher.view SwitcherClosed FileSearchChanged switcherModel

        SidebarContextMenu docId ( x, y ) ->
            [ div [ onClick ModalClosed, id "sidebar-context-overlay" ] []
            , div
                [ id "sidebar-context-menu"
                , style "top" (String.fromFloat y ++ "px")
                , style "left" (String.fromFloat x ++ "px")
                ]
                [ div [ onClick (DuplicateDoc docId), class "context-menu-item" ]
                    [ AntIcons.copyOutlined [ Svg.Attributes.class "icon" ], text language DuplicateDocument ]
                , div [ onClick (DeleteDoc docId), class "context-menu-item" ]
                    [ AntIcons.deleteOutlined [ Svg.Attributes.class "icon" ], text language DeleteDocument ]
                ]
            ]

        TemplateSelector ->
            UI.viewTemplateSelector language
                { modalClosed = ModalClosed
                , importBulkClicked = ImportBulkClicked
                , importTextClicked = ImportTextClicked
                , importOpmlRequested = ImportOpmlRequested
                , importJSONRequested = ImportJSONRequested
                }

        HelpScreen ->
            HelpScreen.view language
                (GlobalData.isMac globalData)
                { closeModal = ModalClosed
                , showVideoTutorials = VideoViewerOpened
                , showWidget = ClickedShowWidget
                , contactSupport = ClickedEmailSupport
                }

        VideoViewer videoViewerState ->
            VideoViewer.view language ModalClosed VideoViewerMsg videoViewerState

        Wordcount docModel ->
            UI.viewWordCount docModel { modalClosed = ModalClosed }

        ImportModal modalModel ->
            ImportModal.view language modalModel
                |> List.map (Html.map ImportModalMsg)

        ImportTextModal modalModel ->
            ImportText.view
                { closeMsg = TemplateSelectorOpened, tagger = ImportTextModalMsg }
                modalModel

        ContactForm contactFormModel ->
            ContactForm.view language
                { closeMsg = ModalClosed
                , submitMsg = ContactFormSubmitted
                , tagger = ContactFormMsg contactFormModel
                , copyEmail = CopyEmailClicked
                }
                contactFormModel

        UpgradeModal ->
            case Session.upgradeModel session of
                Just upgradeModel ->
                    let
                        daysLeft_ =
                            Session.daysLeft (GlobalData.currentTime globalData) session
                    in
                    Upgrade.view daysLeft_ upgradeModel
                        |> List.map (Html.map UpgradeModalMsg)

                Nothing ->
                    []


viewConfirmBanner : Language -> msg -> String -> Html msg
viewConfirmBanner lang closeMsg email =
    div [ id "email-confirm-banner", class "top-banner" ]
        [ AntIcons.warningOutlined [ width 16 ]
        , strong [] [ text lang ConfirmBannerStrong ]
        , textNoTr " "
        , text lang ConfirmBannerBody
        , textNoTr (email ++ " .")
        , AntIcons.closeCircleOutlined [ width 16, height 16, id "email-confirm-close-btn", onClick closeMsg ]
        ]



-- SUBSCRIPTIONS


type AppMsg
    = DataReceived


subscribe : (AppMsg -> msg) -> (String -> msg) -> Sub msg
subscribe tagger onError =
    appMessages
        (\outsideInfo ->
            case outsideInfo.tag of
                "data" ->
                    tagger DataReceived

                _ ->
                    onError <| "Unexpected info from outside: " ++ outsideInfo.tag
        )


port appMessages : (OutsideData -> msg) -> Sub msg


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ subscribe IncomingAppMsg LogErr
        , Incoming.subscribe IncomingDocMsg LogErr
        , Import.Incoming.importComplete
            (\docId_ ->
                case docId_ of
                    Just docId ->
                        ImportJSONCompleted docId

                    Nothing ->
                        ImportBulkCompleted
            )
        , case model.documentState of
            Doc { docModel } ->
                Page.Doc.subscriptions docModel |> Sub.map GotDocMsg

            _ ->
                Sub.none
        , DocList.subscribe ReceivedDocuments
        , Session.userSettingsChange SettingsChanged
        , Session.loginChanges LoginStateChanged
        , case model.modalState of
            ImportModal importModalModel ->
                ImportModal.subscriptions importModalModel
                    |> Sub.map ImportModalMsg

            _ ->
                Sub.none
        , Time.every (9 * 1000) TimeUpdate
        ]
