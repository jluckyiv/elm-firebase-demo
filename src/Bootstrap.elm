module Bootstrap exposing (..)

import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as Json


onChange : (String -> msg) -> Attribute msg
onChange msg =
    on "change" (Json.map msg Json.string)


inputWithButton : (String -> msg) -> msg -> String -> Html msg
inputWithButton updater clicker val =
    div [ class "input-group" ]
        [ input
            [ class "form-control"
            , onInput updater
            , value val
            ]
            []
        , span
            [ class "input-group-btn" ]
            [ button
                [ class "btn btn-primary", onClick clicker ]
                [ text "Go!" ]
            ]
        ]


inputWithLabel : (String -> msg) -> String -> String -> String -> Html msg
inputWithLabel updater id_ lab val =
    div [ class "form-group" ]
        [ label [ for id_ ] [ text lab ]
        , input
            [ class "form-control"
            , onInput updater
            , value val
            ]
            []
        ]


formGroup : (String -> msg) -> String -> String -> String -> Html msg
formGroup msg lab id_ val =
    div [ class "form-group" ]
        [ label [ for id_ ] [ text lab ]
        , input
            [ onInput msg
            , class "form-control"
            , id id_
            , value val
            ]
            []
        ]
