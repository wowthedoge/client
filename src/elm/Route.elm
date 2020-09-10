module Route exposing (Route(..), fromUrl, pushUrl, replaceUrl, toString)

import Browser.Navigation as Nav
import Dict
import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), (<?>), Parser, oneOf, s, string)
import Url.Parser.Query as Q


type Route
    = Home
    | Signup
    | Login
    | Logout
    | DocNew
    | DocUntitled String
    | Doc String String


parser : Parser (Route -> a) a
parser =
    oneOf
        [ Parser.map Home Parser.top
        , Parser.map Signup (s "signup")
        , Parser.map Login (s "login")
        , Parser.map Logout (s "logout")
        , Parser.map DocNew (s "new")
        , Parser.map DocUntitled string
        , Parser.map Doc (string </> string)
        ]


fromUrl : Url -> Maybe Route
fromUrl url =
    Parser.parse parser url


toString : Route -> String
toString route =
    case route of
        Home ->
            "/"

        Signup ->
            "/signup"

        Login ->
            "/login"

        Logout ->
            "/logout"

        DocNew ->
            "/new"

        DocUntitled dbName ->
            "/" ++ dbName

        Doc dbName docName ->
            "/" ++ dbName ++ "/" ++ docName


replaceUrl : Nav.Key -> Route -> Cmd msg
replaceUrl navKey route =
    Nav.replaceUrl navKey (toString route)


pushUrl : Nav.Key -> Route -> Cmd msg
pushUrl navKey route =
    Nav.pushUrl navKey (toString route)
