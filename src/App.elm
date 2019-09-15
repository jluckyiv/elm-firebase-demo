module App exposing (Msg(..), initCmd, update, view)

import Bootstrap as B
import Common.CoreHelpers exposing (ifThenElse, isJust)
import Common.ViewHelpers as ViewHelpers exposing (..)
import Dict exposing (Dict)
import Firebase.Firebase as FB exposing (FBCommand(..))
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Iso8601
import Json.Decode as Decode
import Json.Encode as Encode exposing (Value)
import List as L
import Model as M exposing (..)
import Task
import Time exposing (Posix)


phase2 =
    "2019-11-01"



-- UPDATE


type Msg
    = SwitchTab AppTab
    | ConfirmIsPhase2 Bool
      -- MainList
    | Claim String String
    | Unclaim String String
      -- Suggestions
    | EditSuggestion Present
    | UpdateSuggestionDescription String
    | UpdateSuggestionLink String
    | SubmitSuggestion
    | CancelEditor
    | DeleteSuggestion String
      -- Claims tab
    | TogglePurchased String String Bool -- other user ref, present ref, new value
      -- Settings
    | ToggleNotifications Bool -- turn on/off subscription for notifications of changes
    | Signout
      -- used by Main
    | HandleSnapshot (Maybe FB.FBUser) Value



-- Subscriptions


update : Msg -> Model -> ( Model, Cmd Msg )
update message model =
    case message of
        -- Registration page
        SwitchTab tab ->
            ( { model | tab = tab, editor = blank.editor }, Cmd.none )

        ConfirmIsPhase2 isPhase2 ->
            ( { model | isPhase2 = isPhase2 }, Cmd.none )

        -- Main page
        Claim otherRef presentRef ->
            ( model, claim model.user.uid otherRef presentRef )

        Unclaim otherRef presentRef ->
            ( model
            , Cmd.batch
                [ unclaim otherRef presentRef
                , -- must also set as un-purchased
                  purchase otherRef presentRef False
                ]
            )

        -- Suggestions
        EditSuggestion newPresent ->
            ( updateEditor (\_ -> newPresent) model
            , Cmd.none
            )

        UpdateSuggestionDescription description ->
            ( updateEditor (\ed -> { ed | description = description }) model
            , Cmd.none
            )

        UpdateSuggestionLink link ->
            ( updateEditor
                (\ed -> { ed | link = ifThenElse (link == "") Nothing (Just link) })
                model
            , Cmd.none
            )

        SubmitSuggestion ->
            ( { model | editor = blankPresent }, savePresent model )

        CancelEditor ->
            ( { model | editor = blankPresent }, Cmd.none )

        DeleteSuggestion uid ->
            ( { model | editor = blankPresent }, delete model uid )

        -- Claims
        TogglePurchased otherRef presentRef newValue ->
            ( model, purchase otherRef presentRef newValue )

        -- Misc
        ToggleNotifications notifications ->
            -- this returns to main as "SubscriptionOk", which triggers an update of the db,
            -- which triggers a snapshot that clears this message
            if notifications then
                ( { model | userMessage = Just "Attempting to subscribe" }
                , FB.sendToFirebase <| StartNotifications model.user.uid
                )

            else
                ( { model | userMessage = Just "Attempting to unsubscribe" }
                , FB.sendToFirebase <| StopNotifications model.user.uid
                )

        Signout ->
            ( blank
            , FB.signout
            )

        HandleSnapshot mbUser value ->
            handleSnapshot mbUser value model


{-| If snapshot lacks displayName, then add it to the DB
Now we have the (possible) notifications preference, so use that

FIXME we are renewing subscriptions every time a subscription comes in

-}
handleSnapshot : Maybe FB.FBUser -> Value -> Model -> ( Model, Cmd Msg )
handleSnapshot mbUser snapshot model =
    let
        user =
            mbUser |> Maybe.withDefault model.user
    in
    case Decode.decodeValue (decoderUserData user.uid) snapshot of
        Ok xmas ->
            let
                newModel =
                    { model
                        | xmas = xmas
                        , user = user
                        , -- if we got a snapshot then no need to show progress/error
                          userMessage = Nothing
                    }
            in
            case ( Dict.get newModel.user.uid xmas, newModel.user.displayName ) of
                -- User already registered; copy userName to model (whether needed or not)
                ( Just userData, _ ) ->
                    ( newModel |> setDisplayName userData.meta.name
                      --                    , handleSubscribe userData.meta.notifications
                    , Cmd.none
                    )

                ( Nothing, Just displayName ) ->
                    -- This is a new user as we have the username and the database does not know it
                    -- so we need to set up notifications
                    ( newModel
                    , Cmd.batch
                        [ setMeta newModel.user.uid "name" <| Encode.string displayName

                        --                        , handleSubscribe True
                        ]
                    )

                ( Nothing, Nothing ) ->
                    ( { newModel | userMessage = Just <| "Unexpected error - no display name present" }
                      --                    , rollbar <| "Missing username for: " ++ model.user.uid
                    , Cmd.none
                    )

        -- ( Just userData, Just _ ) ->
        --     -- all subsequent snapshots
        --     ( { model | xmas = xmas }
        --     , renewNotificationsSub userData.meta.notifications
        --       -- , Cmd.none
        --     )
        Err err ->
            ( { model | userMessage = Just <| "handleSnapshot: " ++ Decode.errorToString err }
              --            , rollbar <| "handleSnapshot: " ++ Decode.errorToString err
            , Cmd.none
            )



-- Model update helpers


updateEditor : (Present -> Present) -> Model -> Model
updateEditor fn model =
    { model | editor = fn model.editor }



-- ---------------------------------------
-- VIEW
-- ---------------------------------------


view : Model -> List (Html Msg)
view model =
    let
        ( mine, others ) =
            model.xmas
                |> Dict.toList
                |> L.partition (Tuple.first >> (==) model.user.uid)
    in
    [ viewNavbar model
    , div [ class <| "main " ++ String.toLower (Tuple.second <| stringFromTab model.tab) ] <|
        case model.tab of
            Family ->
                viewFamily model others

            MySuggestions ->
                viewSuggestions model mine

            MyClaims ->
                viewClaims others

            Settings ->
                viewSettings model
    , model.userMessage
        |> Maybe.map (\txt -> footer [ class "container warning" ] [ text txt ])
        |> Maybe.withDefault (viewFooter model.tab)
    ]



-- ------------------
-- Family Tab
-- ------------------


viewFamily : Model -> List ( String, UserData ) -> List (Html Msg)
viewFamily model others =
    let
        fn =
            if model.isPhase2 then
                viewOther

            else
                viewOtherPhase1
    in
    if List.isEmpty others then
        [ text "Awaiting first present ideas" ]

    else
        L.map fn others


viewOtherPhase1 : ( String, UserData ) -> Html Msg
viewOtherPhase1 ( _, { meta, presents } ) =
    div [ class "person section" ]
        [ div [] [ text <| meta.name ++ ": " ++ String.fromInt (Dict.size presents) ++ " suggestion(s)" ] ]


viewOther : ( String, UserData ) -> Html Msg
viewOther ( userRef, { meta, presents } ) =
    let
        viewPresent presentRef present =
            let
                ( cls, htm ) =
                    case present.status of
                        Available ->
                            ( "available"
                            , button
                                [ class "btn btn-primary btn-sm"
                                , onClick <| Claim userRef presentRef
                                ]
                                [ text "Claim" ]
                            )

                        ClaimedByMe _ ->
                            ( "ClaimedByMe"
                            , button
                                [ class "btn btn-success btn-sm"
                                , onClick <| Unclaim userRef presentRef
                                ]
                                [ text "Claimed" ]
                            )

                        ClaimedBySomeone ->
                            ( "text-secondary", badge "light" "Taken" )
            in
            li [ class <| "present flex-h " ++ cls ]
                [ makeDescription present
                , htm
                ]

        ps =
            presents
                |> Dict.map viewPresent
                |> Dict.values
    in
    case ps of
        [] ->
            text ""

        _ ->
            div [ class "shadow-sm bg-white rounded person section" ]
                [ h4 [] [ text meta.name ]
                , ul [ class "present-list" ] ps
                ]



-- ------------------
-- Suggestions Tab
-- ------------------


viewSuggestions : Model -> List ( String, UserData ) -> List (Html Msg)
viewSuggestions model lst =
    let
        viewPresent present =
            li [ class "present flex-h flex-spread" ]
                [ makeDescription present
                , button
                    [ onClick (EditSuggestion present)
                    , class "btn btn-success btn-sm"
                    ]
                    [ span [ class "mr-1" ] [ matIcon "pencil-outline" ]
                    , text "Edit"
                    ]
                ]

        myPresents =
            case lst of
                [ ( _, { presents } ) ] ->
                    case Dict.values presents of
                        [] ->
                            text "Time to add you first idea!"

                        lst_ ->
                            lst_
                                |> L.map viewPresent
                                |> ul [ class "present-list" ]

                [] ->
                    text "Time to add you first idea!"

                _ ->
                    text <| "Unexpected error - too many entries in your name - please report this"
    in
    [ viewPresentEditor model.isPhase2 model.editor
    , div [ class "my-presents section" ] [ myPresents ]
    ]


viewPresentEditor : Bool -> Present -> Html Msg
viewPresentEditor isPhase2 editor =
    div [ class "new-present section" ]
        [ h4 []
            [ case editor.uid of
                Just _ ->
                    text "Edit suggestion"

                Nothing ->
                    text "New suggestion"
            ]
        , div [ id "new-present-form" ]
            [ B.inputWithLabel UpdateSuggestionDescription "Description" "newpresent" editor.description
            , editor.link
                |> Maybe.withDefault ""
                |> B.inputWithLabel UpdateSuggestionLink "Link (optional)" "newpresentlink"
            , div [ class "flex-h flex-spread" ]
                [ button [ class "btn btn-warning", onClick CancelEditor ] [ text "Cancel" ]
                , case editor.uid of
                    Just uid ->
                        button [ class "btn btn-danger", onClick (DeleteSuggestion uid) ] [ text "Delete*" ]

                    Nothing ->
                        text ""
                , button
                    [ class "btn btn-success"
                    , onClick SubmitSuggestion
                    , disabled <| editor.description == ""
                    ]
                    [ text "Save" ]
                ]
            , if isPhase2 then
                div [ class "mt-1" ] [ text "* Warning: someone may already have committed to buy this!" ]

              else
                text ""
            ]
        ]


makeDescription : Present -> Html Msg
makeDescription { description, link } =
    case link of
        Just link_ ->
            div [ class "description" ]
                [ text description
                , a [ href link_, target "_blank" ] [ matIcon "open-in-new" ]
                ]

        Nothing ->
            text description



-- ------------------
-- Claims Tab
-- ------------------


viewClaims : List ( String, UserData ) -> List (Html Msg)
viewClaims others =
    let
        mkItem : String -> String -> Present -> Bool -> Html Msg
        mkItem oRef presentRef present purchased =
            let
                ( status, cls ) =
                    if purchased then
                        ( "Purchased", class "btn btn-success btn-sm" )

                    else
                        ( "Claimed", class "btn btn-warning btn-sm" )
            in
            li [ class "present flex-h flex-spread" ]
                [ makeDescription present
                , button [ onClick <| TogglePurchased oRef presentRef (not purchased), cls ] [ text status ]
                ]

        mkItemsForPerson : ( String, UserData ) -> Maybe (Html Msg)
        mkItemsForPerson ( oRef, other ) =
            let
                claimsForPerson =
                    other.presents
                        |> Dict.toList
                        |> L.filterMap
                            (\( presentRef, present ) ->
                                case present.status of
                                    ClaimedByMe purchased ->
                                        Just <| mkItem oRef presentRef present purchased

                                    _ ->
                                        Nothing
                            )
            in
            if List.isEmpty claimsForPerson then
                Nothing

            else
                Just <|
                    div [ class "person section" ]
                        [ h4 [] [ text other.meta.name ]
                        , ul [ class "present-list" ] claimsForPerson
                        ]
    in
    case L.filterMap mkItemsForPerson others of
        [] ->
            [ text "You currently have no claims" ]

        lst ->
            lst



-- ------------------
-- Settings Tab
-- ------------------


viewSettings : Model -> List (Html Msg)
viewSettings model =
    let
        notifications =
            model.xmas
                |> Dict.get model.user.uid
                |> Maybe.map (.meta >> .notifications)
                |> Maybe.withDefault True
    in
    [ div [ class "section settings" ]
        [ h4 [] [ text "Settings" ]
        , ul [ class "present-list" ]
            [ mkPresentTmpl
                [ div [] [ text "Notifications" ]
                , span [ onClick (ToggleNotifications <| not notifications) ]
                    [ if notifications then
                        badge "success clickable" "on"

                      else
                        badge "danger clickable" "off"
                    ]
                ]
            , mkPresentTmpl
                [ div [ class "text-danger" ] [ text "Signout" ]
                , div [ class "text-danger" ] [ matIconMsg Signout "logout" ]
                ]
            ]
        ]
    ]


mkPresentTmpl htms =
    li [ class "present flex-h" ] htms



--


viewNavbar : Model -> Html Msg
viewNavbar model =
    header [ class "flex-h flex-aligned flex-spread" ]
        [ h4 [] [ text "Xmas 2017" ]
        , div [ class "flex-h flex-aligned" ]
            [ model.user.displayName
                |> Maybe.map (text >> L.singleton >> strong [])
                |> Maybe.withDefault (text "Xmas Present ideas")
            , case model.user.photoURL of
                Just photoURL ->
                    img [ src photoURL, class "avatar", alt "avatar" ] []

                Nothing ->
                    text ""
            ]
        ]


viewFooter : AppTab -> Html Msg
viewFooter tab =
    [ Family, MySuggestions, MyClaims, Settings ]
        |> L.map (\t -> ViewHelpers.mkTab SwitchTab t tab <| stringFromTab t)
        |> footer [ class "tabs" ]



-- CMDs


claim : String -> String -> String -> Cmd msg
claim uid otherRef presentRef =
    FB.set
        (makeSetPresentRef "takenBy" otherRef presentRef)
        (Encode.string uid)


purchase : String -> String -> Bool -> Cmd msg
purchase otherRef presentRef purchased =
    FB.set
        (makeSetPresentRef "purchased" otherRef presentRef)
        (Encode.bool purchased)


unclaim : String -> String -> Cmd msg
unclaim otherRef presentRef =
    FB.remove <| makeSetPresentRef "takenBy" otherRef presentRef


delete : Model -> String -> Cmd Msg
delete model ref =
    FB.remove ("/" ++ model.user.uid ++ "/presents/" ++ ref)


savePresent : Model -> Cmd Msg
savePresent model =
    case model.editor.uid of
        Just uid_ ->
            -- update existing present
            -- FIXME should UPDATE description and link, NOT REPLACE everything
            FB.update ("/" ++ model.user.uid ++ "/presents/" ++ uid_) (encodePresent model.user.uid model.editor)

        Nothing ->
            FB.push ("/" ++ model.user.uid ++ "/presents") (encodePresent model.user.uid model.editor)


setMeta : String -> String -> Encode.Value -> Cmd msg
setMeta uid key val =
    FB.set ("/" ++ uid ++ "/meta/" ++ key) val


makeSetPresentRef : String -> String -> String -> String
makeSetPresentRef str otherRef presentRef =
    [ otherRef, "presents", presentRef, str ] |> String.join "/"


initCmd =
    Time.now
        |> Task.map checkIfPhase2
        |> Task.perform ConfirmIsPhase2


checkIfPhase2 : Posix -> Bool
checkIfPhase2 now =
    case Iso8601.toTime phase2 of
        Ok endPhase1 ->
            Time.posixToMillis now > Time.posixToMillis endPhase1

        Err _ ->
            False
