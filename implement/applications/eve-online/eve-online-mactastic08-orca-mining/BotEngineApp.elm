{- Mactastic08 orca mining version 2020-09-19
   Engage drones part of https://forum.botengine.org/t/orca-targeting-mining/3591
-}
{-
   app-catalog-tags:eve-online,mining
   authors-forum-usernames:viir
-}


module BotEngineApp exposing
    ( State
    , initState
    , processEvent
    )

import BotEngine.Interface_To_Host_20200824 as InterfaceToHost
import Common.AppSettings as AppSettings
import Common.DecisionTree exposing (describeBranch)
import Common.EffectOnWindow exposing (MouseButton(..))
import Dict
import EveOnline.AppFramework
    exposing
        ( AppEffect(..)
        , DecisionPathNode
        , ReadingFromGameClient
        , ShipModulesMemory
        , menuCascadeCompleted
        , useContextMenuCascade
        , useMenuEntryWithTextContaining
        , waitForProgressInGame
        )
import EveOnline.ParseUserInterface exposing (getAllContainedDisplayTexts)


defaultBotSettings : BotSettings
defaultBotSettings =
    { modulesToActivateAlways = [] }


parseBotSettings : String -> Result String BotSettings
parseBotSettings =
    AppSettings.parseSimpleListOfAssignments { assignmentsSeparators = [ ",", "\n" ] }
        ([ ( "module-to-activate-always"
           , AppSettings.valueTypeString (\moduleName -> \settings -> { settings | modulesToActivateAlways = moduleName :: settings.modulesToActivateAlways })
           )
         ]
            |> Dict.fromList
        )
        defaultBotSettings


type alias BotSettings =
    { modulesToActivateAlways : List String
    }


type alias BotMemory =
    { lastSolarSystemName : Maybe String
    , jumpsCompleted : Int
    , shipModules : ShipModulesMemory
    }


type alias StateMemoryAndDecisionTree =
    EveOnline.AppFramework.AppStateWithMemoryAndDecisionTree BotMemory


type alias State =
    EveOnline.AppFramework.StateIncludingFramework BotSettings StateMemoryAndDecisionTree


type alias BotDecisionContext =
    EveOnline.AppFramework.StepDecisionContext BotSettings BotMemory


initState : State
initState =
    EveOnline.AppFramework.initState
        (EveOnline.AppFramework.initStateWithMemoryAndDecisionTree
            { lastSolarSystemName = Nothing
            , jumpsCompleted = 0
            , shipModules = EveOnline.AppFramework.initShipModulesMemory
            }
        )


statusTextFromState : BotDecisionContext -> String
statusTextFromState context =
    let
        describeSessionPerformance =
            "jumps completed: " ++ (context.memory.jumpsCompleted |> String.fromInt)

        describeCurrentReading =
            "current solar system: "
                ++ (currentSolarSystemNameFromReading context.readingFromGameClient |> Maybe.withDefault "Unknown")
    in
    [ describeSessionPerformance
    , describeCurrentReading
    ]
        |> String.join "\n"


mactastic08_orca_mining_BotDecisionRoot : BotDecisionContext -> DecisionPathNode
mactastic08_orca_mining_BotDecisionRoot context =
    -- Engage drones part of https://forum.botengine.org/t/orca-targeting-mining/3591
    launchAndEngageDrones context.readingFromGameClient
        |> Maybe.withDefault (describeBranch "Drones already engaged" waitForProgressInGame)


launchAndEngageDrones : ReadingFromGameClient -> Maybe DecisionPathNode
launchAndEngageDrones readingFromGameClient =
    readingFromGameClient.dronesWindow
        |> Maybe.andThen
            (\dronesWindow ->
                case ( dronesWindow.droneGroupInBay, dronesWindow.droneGroupInLocalSpace ) of
                    ( Just droneGroupInBay, Just droneGroupInLocalSpace ) ->
                        let
                            idlingDrones =
                                droneGroupInLocalSpace.drones
                                    |> List.filter (.uiNode >> .uiNode >> EveOnline.ParseUserInterface.getAllContainedDisplayTexts >> List.any (String.toLower >> String.contains "idle"))

                            dronesInBayQuantity =
                                droneGroupInBay.header.quantityFromTitle |> Maybe.withDefault 0

                            dronesInLocalSpaceQuantity =
                                droneGroupInLocalSpace.header.quantityFromTitle |> Maybe.withDefault 0
                        in
                        if 0 < (idlingDrones |> List.length) then
                            Just
                                (describeBranch "Engage idling drone(s)"
                                    (useContextMenuCascade
                                        ( "drones group", droneGroupInLocalSpace.header.uiNode )
                                        (useMenuEntryWithTextContaining "engage target" menuCascadeCompleted)
                                    )
                                )

                        else if 0 < dronesInBayQuantity && dronesInLocalSpaceQuantity < 5 then
                            Just
                                (describeBranch "Launch drones"
                                    (useContextMenuCascade
                                        ( "drones group", droneGroupInBay.header.uiNode )
                                        (useMenuEntryWithTextContaining "Launch drone" menuCascadeCompleted)
                                    )
                                )

                        else
                            Nothing

                    _ ->
                        Nothing
            )


updateMemoryForNewReadingFromGame : ReadingFromGameClient -> BotMemory -> BotMemory
updateMemoryForNewReadingFromGame currentReading memoryBefore =
    let
        ( lastSolarSystemName, newJumpsCompleted ) =
            case currentSolarSystemNameFromReading currentReading of
                Nothing ->
                    ( memoryBefore.lastSolarSystemName, 0 )

                Just currentSolarSystemName ->
                    ( Just currentSolarSystemName
                    , if
                        (memoryBefore.lastSolarSystemName /= Nothing)
                            && (memoryBefore.lastSolarSystemName /= Just currentSolarSystemName)
                      then
                        1

                      else
                        0
                    )
    in
    { jumpsCompleted = memoryBefore.jumpsCompleted + newJumpsCompleted
    , lastSolarSystemName = lastSolarSystemName
    , shipModules =
        EveOnline.AppFramework.integrateCurrentReadingsIntoShipModulesMemory
            currentReading
            memoryBefore.shipModules
    }


processEveOnlineBotEvent :
    EveOnline.AppFramework.AppEventContext BotSettings
    -> EveOnline.AppFramework.AppEvent
    -> StateMemoryAndDecisionTree
    -> ( StateMemoryAndDecisionTree, EveOnline.AppFramework.AppEventResponse )
processEveOnlineBotEvent =
    EveOnline.AppFramework.processEveOnlineAppEventWithMemoryAndDecisionTree
        { updateMemoryForNewReadingFromGame = updateMemoryForNewReadingFromGame
        , decisionTreeRoot = mactastic08_orca_mining_BotDecisionRoot
        , statusTextFromState = statusTextFromState
        , millisecondsToNextReadingFromGame = always 2000
        }


processEvent : InterfaceToHost.AppEvent -> State -> ( State, InterfaceToHost.AppResponse )
processEvent =
    EveOnline.AppFramework.processEvent
        { parseAppSettings = parseBotSettings
        , selectGameClientInstance = always EveOnline.AppFramework.selectGameClientInstanceWithTopmostWindow
        , processEvent = processEveOnlineBotEvent
        }


currentSolarSystemNameFromReading : ReadingFromGameClient -> Maybe String
currentSolarSystemNameFromReading readingFromGameClient =
    readingFromGameClient.infoPanelContainer
        |> Maybe.andThen .infoPanelLocationInfo
        |> Maybe.andThen .currentSolarSystemName
