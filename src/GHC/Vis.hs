{-# LANGUAGE CPP, RankNTypes, ImpredicativeTypes #-}
{- |
   Module      : GHC.Vis
   Copyright   : (c) Dennis Felsing
   License     : 3-Clause BSD-style
   Maintainer  : dennis@felsin9.de

Although ghc-vis is meant to be used in GHCi it can also be used as a library
in regular Haskell programs which are run or compiled by GHC. You can run those
programs using \"runghc example.hs\" or \"ghc -threaded example.hs && ./example\".
Without the \"-threaded\"-Flag ghc-vis does not work correctly. This is an
example using ghc-vis outside of GHCi:

> import GHC.Vis
>
> main = do
>   putStrLn "Start"
>   let a = "teeest"
>   let b = [1..3]
>   let c = b ++ b
>   let d = [1..]
>   putStrLn $ show $ d !! 1
>
>   visualization
>   view a "a"
>   view b "b"
>   view c "c"
>   view d "d"
>
>   getChar
>   switch
>
>   getChar
>   putStrLn "End"
 -}
module GHC.Vis (
  vis,
  mvis,
#ifdef SDL_WINDOW
  svis,
#endif
  view,
  eval,
  switch,
  update,
  clear,
  history,
  export
  )
  where

#if __GLASGOW_HASKELL__ < 706
import Prelude hiding (catch, error)
#else
import Prelude hiding (error)
#endif

import Graphics.UI.Gtk hiding (Box, Signal, get, response)
import qualified Graphics.UI.Gtk.Gdk.Events as E

import System.IO
import Control.Concurrent
import Control.Monad

import Control.Exception hiding (evaluate)

import Data.Char
import Data.IORef

import qualified Data.IntMap as M

import System.Timeout
import System.Mem

import GHC.HeapView hiding (name)

import GHC.Vis.Types hiding (view)
import qualified GHC.Vis.Types as T
import GHC.Vis.View.Common
import qualified GHC.Vis.View.List as List

#ifdef GRAPH_VIEW
import Data.GraphViz.Commands
import qualified GHC.Vis.View.Graph as Graph
#endif

import Graphics.Rendering.Cairo

#ifdef FULL_WINDOW
import Graphics.Rendering.Cairo.SVG
import Paths_ghc_vis as My
#endif

#ifdef SDL_WINDOW
import qualified Graphics.UI.SDL as SDL
import Foreign.Ptr ( castPtr )
#endif

views :: [View]
views =
  View List.redraw List.click List.move List.updateObjects List.export :
#ifdef GRAPH_VIEW
  View Graph.redraw Graph.click Graph.move Graph.updateObjects Graph.export :
#endif
  []

title :: String
title = "ghc-vis"

backgroundColor :: Color
backgroundColor = Color 0xffff 0xffff 0xffff

defaultSize :: (Int, Int)
defaultSize = (640, 480)

zoomIncrement :: Double
zoomIncrement = 1.25

positionIncrement :: Double
positionIncrement = 50

bigPositionIncrement :: Double
bigPositionIncrement = 200

signalTimeout :: Int
signalTimeout = 1000000

#ifdef SDL_WINDOW
black = SDL.Pixel maxBound
white = SDL.Pixel 0xFFFFFF
#endif

-- | This is the main function. It's to be called from GHCi and launches a
--   graphical window in a new thread.
vis :: IO ()
#ifdef FULL_WINDOW
vis = do
  vr <- swapMVar visRunning True
  unless vr $ void $ forkIO visMainThread
#else
vis = mvis
#endif

-- | A minimalistic version of ghc-vis, without window decorations, help and
--   all that other stuff.
mvis :: IO ()
mvis = do
  vr <- swapMVar visRunning True
  unless vr $ void $ forkIO mVisMainThread

#ifdef SDL_WINDOW
-- | SDL version. Not properly working yet. Mainly for testing whether SDL
--   works better than GTK on some platforms.
svis :: IO ()
svis = do
  vr <- swapMVar visRunning True
  unless vr $ void $ forkIO sdlVisMainThread
#endif

-- | Add expressions with a name to the visualization window.
view :: a -> String -> IO ()
view a name = put $ NewSignal (asBox a) name

-- | Evaluate an object that is shown in the visualization. (Names start with 't')
eval :: String -> IO ()
eval t = evaluate t >> update

-- | Switch between the list view and the graph view
switch :: IO ()
switch = put SwitchSignal

-- | When an object is updated by accessing it, you have to call this to
--   refresh the visualization window. You can also click on an object to force
--   an update.
update :: IO ()
update = put UpdateSignal

-- | Clear the visualization window, removing all expressions from it.
clear :: IO ()
clear = put ClearSignal

-- | Change position in history
history :: (Int -> Int) -> IO ()
history = put . HistorySignal

-- | Export the current visualization view to a file, format depends on the
--   file ending. Currently supported: svg, png, pdf, ps
export :: String -> IO ()
export filename = void $ export' filename

export' :: String -> IO (Maybe String)
export' filename = case mbDrawFn of
  Right error -> do putStrLn error
                    return $ Just error
  Left _ -> do put $ ExportSignal ((\(Left x) -> x) mbDrawFn) filename
               return Nothing

  where mbDrawFn = case map toLower (reverse . take 4 . reverse $ filename) of
          ".svg"  -> Left withSVGSurface
          ".pdf"  -> Left withPDFSurface
          ".png"  -> Left withPNGSurface
          _:".ps" -> Left withPSSurface
          _       -> Right "Unknown file extension, try one of the following: .svg, .pdf, .ps, .png"

        withPNGSurface filePath width height action =
          withImageSurface FormatARGB32 (ceiling width) (ceiling height) $
          \surface -> do
            ret <- action surface
            surfaceWriteToPNG surface filePath
            return ret

put :: Signal -> IO ()
put s = void $ timeout signalTimeout $ putMVar visSignal s

mVisMainThread :: IO ()
mVisMainThread = do
  initGUI
  window <- windowNew

  canvas <- drawingAreaNew

  widgetModifyBg canvas StateNormal backgroundColor

  set window [ windowTitle := title
             , containerChild := canvas
             ]
  (uncurry $ windowSetDefaultSize window) defaultSize

  onExpose canvas $ const $ do
    runCorrect redraw >>= \f -> f canvas
    runCorrect move >>= \f -> f canvas
    return True

  dummy <- windowNew

  setupGUI window canvas dummy

#ifdef SDL_WINDOW
sdlVisMainThread :: IO ()
sdlVisMainThread = SDL.withInit [ SDL.InitVideo ] $ do
  screen <- SDL.setVideoMode 600 600 32 [ SDL.Resizable ]

  SDL.fillRect screen Nothing black

  pixels <- fmap castPtr $ SDL.surfaceGetPixels screen

  -- Here we test the first of the user facing functions added by the patch.
  -- Be sure to use FORMATRGB24 so Cairo and SDL don't conflict about alpha
  -- values. If you need to use alpha channel in your Cairo routines, consider
  -- using an independent Cairo surface to buffer your alpha drawing to.
  --renderWith canvas demo1

  -- And here is the other new function for when you want to hide the
  -- Cairo.Surface from the caller.

  canvas <- createImageSurfaceForData pixels FormatRGB24 600 600 (600 * 4)

  reactThread <- forkIO $ react2

  let idle = do
        e <- SDL.waitEvent
        case e of
          SDL.Quit -> quit reactThread
          otherwise -> do
            putStrLn "Updating"
            s <- List.getState
            SDL.fillRect screen Nothing white
            boundingBoxes <- renderWith canvas $ List.draw s 600 600
            List.updateBoundingBoxes boundingBoxes
            SDL.flip screen
            idle

  idle
#endif

setupGUI :: (WidgetClass w1, WidgetClass w2, WidgetClass w3) => w1 -> w2 -> w3 -> IO ()
setupGUI window canvas legendCanvas = do
  onMotionNotify canvas False $ \e -> do
    state <- readIORef visState
    modifyIORef visState (\s -> s {mousePos = (E.eventX e, E.eventY e)})

    if dragging state
    then do
      let (oldX, oldY) = mousePos state
          (deltaX, deltaY) = (E.eventX e - oldX, E.eventY e - oldY)
          (oldPosX, oldPosY) = position state
      modifyIORef visState (\s -> s {position = (oldPosX + deltaX, oldPosY + deltaY)})
      widgetQueueDraw canvas
    else
      runCorrect move >>= \f -> f canvas

    return True

  onButtonPress canvas $ \e -> do
    when (E.eventButton e == LeftButton && E.eventClick e == SingleClick) $
      join $ runCorrect click

    when (E.eventButton e == RightButton && E.eventClick e == SingleClick) $
      modifyIORef visState (\s -> s {dragging = True})

    when (E.eventButton e == MiddleButton && E.eventClick e == SingleClick) $ do
      modifyIORef visState (\s -> s {zoomRatio = 1, position = (0, 0)})
      widgetQueueDraw canvas

    return True

  onButtonRelease canvas $ \e -> do
    when (E.eventButton e == RightButton) $
      modifyIORef visState (\s -> s {dragging = False})

    return True

  onScroll canvas $ \e -> do
    state <- readIORef visState

    when (E.eventDirection e == ScrollUp) $ do
      let newZoomRatio = zoomRatio state * zoomIncrement
      newPos <- zoomImage canvas state newZoomRatio (mousePos state)
      modifyIORef visState (\s -> s {zoomRatio = newZoomRatio, position = newPos})

    when (E.eventDirection e == ScrollDown) $ do
      let newZoomRatio = zoomRatio state / zoomIncrement
      newPos <- zoomImage canvas state newZoomRatio (mousePos state)
      modifyIORef visState (\s -> s {zoomRatio = newZoomRatio, position = newPos})

    widgetQueueDraw canvas
    return True

  onKeyPress window $ \e -> do
    --putStrLn $ E.eventKeyName e

    state <- readIORef visState

    when (E.eventKeyName e `elem` ["plus", "Page_Up", "KP_Add"]) $ do
      let newZoomRatio = zoomRatio state * zoomIncrement
          (oldX, oldY) = position state
          newPos = (oldX*zoomIncrement, oldY*zoomIncrement)
      modifyIORef visState (\s -> s {zoomRatio = newZoomRatio, position = newPos})

    when (E.eventKeyName e `elem` ["minus", "Page_Down", "KP_Subtract"]) $ do
      let newZoomRatio = zoomRatio state / zoomIncrement
          (oldX, oldY) = position state
          newPos = (oldX/zoomIncrement, oldY/zoomIncrement)
      modifyIORef visState (\s -> s {zoomRatio = newZoomRatio, position = newPos})

    when (E.eventKeyName e `elem` ["0", "equal"]) $
      modifyIORef visState (\s -> s {zoomRatio = 1, position = (0, 0)})

    when (E.eventKeyName e `elem` ["Left", "h", "a"]) $
      modifyIORef visState (\s ->
        let (x,y) = position s
            newX  = x + positionIncrement
        in s {position = (newX, y)})

    when (E.eventKeyName e `elem` ["Right", "l", "d"]) $
      modifyIORef visState (\s ->
        let (x,y) = position s
            newX  = x - positionIncrement
        in s {position = (newX, y)})

    when (E.eventKeyName e `elem` ["Up", "k", "w"]) $
      modifyIORef visState (\s ->
        let (x,y) = position s
            newY  = y + positionIncrement
        in s {position = (x, newY)})

    when (E.eventKeyName e `elem` ["Down", "j", "s"]) $
      modifyIORef visState (\s ->
        let (x,y) = position s
            newY  = y - positionIncrement
        in s {position = (x, newY)})

    when (E.eventKeyName e `elem` ["H", "A"]) $
      modifyIORef visState (\s ->
        let (x,y) = position s
            newX  = x + bigPositionIncrement
        in s {position = (newX, y)})

    when (E.eventKeyName e `elem` ["L", "D"]) $
      modifyIORef visState (\s ->
        let (x,y) = position s
            newX  = x - bigPositionIncrement
        in s {position = (newX, y)})

    when (E.eventKeyName e `elem` ["K", "W"]) $
      modifyIORef visState (\s ->
        let (x,y) = position s
            newY  = y + bigPositionIncrement
        in s {position = (x, newY)})

    when (E.eventKeyName e `elem` ["J", "S"]) $
      modifyIORef visState (\s ->
        let (x,y) = position s
            newY  = y - bigPositionIncrement
        in s {position = (x, newY)})

    when (E.eventKeyName e `elem` ["space", "Return", "KP_Enter"]) $
      join $ runCorrect click

    when (E.eventKeyName e `elem` ["v"]) $
      put SwitchSignal

    when (E.eventKeyName e `elem` ["c"]) $
      put ClearSignal

    when (E.eventKeyName e `elem` ["u"]) $
      put UpdateSignal

    when (E.eventKeyName e `elem` ["comma", "bracketleft"]) $
      put $ HistorySignal (+1)

    when (E.eventKeyName e `elem` ["period", "bracketright"]) $
      put $ HistorySignal (\x -> x - 1)

    widgetQueueDraw canvas
    return True

  widgetShowAll window

  reactThread <- forkIO $ react canvas legendCanvas
  --onDestroy window mainQuit -- Causes :r problems with multiple windows
  onDestroy window (quit reactThread)

  mainGUI
  return ()

quit :: ThreadId -> IO ()
quit reactThread = do
  swapMVar visRunning False
  killThread reactThread

#ifdef SDL_WINDOW
react2 :: IO b
react2 = do
  -- Timeout used to handle ghci reloads (:r)
  -- Reloads cause the visSignal to be reinitialized, but takeMVar is still
  -- waiting for the old one.  This solution is not perfect, but it works for
  -- now.
  mbSignal <- timeout signalTimeout (takeMVar visSignal)
  case mbSignal of
    Nothing -> do
      running <- readMVar visRunning
      if running then react2 else
        -- :r caused visRunning to be reset
        (do swapMVar visRunning True
            timeout signalTimeout (putMVar visSignal UpdateSignal)
            react2)
    Just signal -> do
      case signal of
        NewSignal x n  -> modifyMVar_ visBoxes (
          \y -> return $ if (x,n) `elem` y then y else y ++ [(x,n)])
        ClearSignal    -> modifyMVar_ visBoxes (\_ -> return [])
        UpdateSignal   -> return ()
        SwitchSignal   -> doSwitch
        ExportSignal d f -> catch (runCorrect exportView >>= \e -> e d f)
          (\e -> do let err = show (e :: IOException)
                    hPutStrLn stderr $ "Couldn't export to file \"" ++ f ++ "\": " ++ err
                    return ())

      boxes <- readMVar visBoxes
      performGC -- TODO: Else Blackholes appear. Do we want this?
                -- Blackholes stop our current thread and only resume after
                -- they have been replaced with their result, thereby leading
                -- to an additional element in the HeapMap we don't want.
                -- Example for bad behaviour that would happen then:
                -- λ> let xs = [1..42] :: [Int]
                -- λ> let x = 17 :: Int
                -- λ> let ys = [ y | y <- xs, y >= x ]

      runCorrect updateObjects >>= \f -> f boxes

      --postGUISync $ widgetQueueDraw canvas
      --postGUISync $ widgetQueueDraw legendCanvas
      react2

#ifdef GRAPH_VIEW
  where doSwitch = isGraphvizInstalled >>= \gvi -> if gvi
          then modifyIORef visState (\s -> s {T.view = succN (T.view s), zoomRatio = 1, position = (0, 0)})
          else putStrLn "Cannot switch view: The Graphviz binary (dot) is not installed"

        succN GraphView = ListView
        succN ListView = GraphView
#else
  where doSwitch = putStrLn "Cannot switch view: Graph view disabled at build"
#endif
#endif

react :: (WidgetClass w1, WidgetClass w2) => w1 -> w2 -> IO b
react canvas legendCanvas = do
  -- Timeout used to handle ghci reloads (:r)
  -- Reloads cause the visSignal to be reinitialized, but takeMVar is still
  -- waiting for the old one.  This solution is not perfect, but it works for
  -- now.
  mbSignal <- timeout signalTimeout (takeMVar visSignal)
  case mbSignal of
    Nothing -> do
      running <- readMVar visRunning
      if running then react canvas legendCanvas else
        -- :r caused visRunning to be reset
        (do swapMVar visRunning True
            timeout signalTimeout (putMVar visSignal UpdateSignal)
            react canvas legendCanvas)
    Just signal -> do
      doUpdate <- case signal of
        NewSignal x n  -> do
          modifyMVar_ visBoxes (\y -> return $ if ([n], x) `elem` y then y else y ++ [([n], x)])
          return True
        ClearSignal    -> do
          modifyMVar_ visBoxes $ const $ return []
          modifyMVar_ visHeapHistory $ const $ return (0, [(HeapGraph M.empty, [])])
          return False
        UpdateSignal   -> return True
        SwitchSignal   -> doSwitch >> return False
        HistorySignal f -> do
          modifyMVar_ visHeapHistory (\(i,xs) -> return (max 0 (min (length xs - 1) (f i)), xs))
          return False
        ExportSignal d f -> do
          catch (runCorrect exportView >>= \e -> e d f)
            (\e -> do let err = show (e :: IOException)
                      hPutStrLn stderr $ "Couldn't export to file \"" ++ f ++ "\": " ++ err
                      return ())
          return False

      boxes <- readMVar visBoxes

      when doUpdate $ do
        performGC -- TODO: Else Blackholes appear. Do we want this?
                  -- Blackholes stop our current thread and only resume after
                  -- they have been replaced with their result, thereby leading
                  -- to an additional element in the HeapMap we don't want.
                  -- Example for bad behaviour that would happen then:
                  -- λ> let xs = [1..42] :: [Int]
                  -- λ> let x = 17 :: Int
                  -- λ> let ys = [ y | y <- xs, y >= x ]

        x <- multiBuildHeapGraph 100 boxes
        modifyMVar_ visHeapHistory (\(i,xs) -> return (i,x:xs))

      runCorrect updateObjects >>= \f -> f boxes

      postGUISync $ widgetQueueDraw canvas
      postGUISync $ widgetQueueDraw legendCanvas
      react canvas legendCanvas

#ifdef GRAPH_VIEW
  where doSwitch = isGraphvizInstalled >>= \gvi -> if gvi
          then modifyIORef visState (\s -> s {T.view = succN (T.view s), zoomRatio = 1, position = (0, 0)})
          else putStrLn "Cannot switch view: The Graphviz binary (dot) is not installed"

        succN GraphView = ListView
        succN ListView = GraphView
#else
  where doSwitch = putStrLn "Cannot switch view: Graph view disabled at build"
#endif

runCorrect :: (View -> f) -> IO f
runCorrect f = do
  s <- readIORef visState
  return $ f $ views !! fromEnum (T.view s)

zoomImage :: WidgetClass w1 => w1 -> State -> Double -> T.Point -> IO T.Point
zoomImage _canvas s newZoomRatio _mousePos@(_x', _y') = do
  -- TODO: Mouse must stay at same spot

  --E.Rectangle _ _ rw' rh' <- widgetGetAllocation canvas
  --let (rw, rh) = (fromIntegral rw', fromIntegral rh')
  --let (x,y) = (x' - rw / 2, y' - rh / 2)

  let (oldPosX, oldPosY) = position s
      zoom = newZoomRatio / zoomRatio s
      newPos = (oldPosX * zoom, oldPosY * zoom)

  return newPos

#ifdef FULL_WINDOW
visMainThread :: IO ()
visMainThread = do
  initGUI

  mainUIFile <- My.getDataFileName "data/main.ui"
  builder <- builderNew
  builderAddFromFile builder mainUIFile

  let get :: forall cls . GObjectClass cls
          => (GObject -> cls)
          -> String
          -> IO cls
      get = builderGetObject builder

  window       <- get castToWindow "window"
  canvas       <- get castToDrawingArea "drawingarea"

  saveDialog   <- get castToFileChooserDialog "savedialog"
  aboutDialog  <- get castToAboutDialog "aboutdialog"

  legendDialog <- get castToWindow "legenddialog"
  legendCanvas <- get castToDrawingArea "legenddrawingarea"

  newFilter "*.pdf" "PDF" saveDialog
  newFilter "*.svg" "SVG" saveDialog
  newFilter "*.ps" "PostScript" saveDialog
  newFilter "*.png" "PNG" saveDialog

  onResponse saveDialog $ fileSave saveDialog
  onResponse aboutDialog $ const $ widgetHide aboutDialog

  onDelete saveDialog   $ const $ widgetHide saveDialog   >> return True
  onDelete aboutDialog  $ const $ widgetHide aboutDialog  >> return True
  onDelete legendDialog $ const $ widgetHide legendDialog >> return True

  get castToMenuItem "clear"  >>= \item -> onActivateLeaf item clear
  get castToMenuItem "switch" >>= \item -> onActivateLeaf item switch
  get castToMenuItem "update" >>= \item -> onActivateLeaf item update
  get castToMenuItem "export" >>= \item -> onActivateLeaf item $ widgetShow saveDialog
  get castToMenuItem "quit"   >>= \item -> onActivateLeaf item $ widgetDestroy window
  get castToMenuItem "about"  >>= \item -> onActivateLeaf item $ widgetShow aboutDialog
  get castToMenuItem "legend" >>= \item -> onActivateLeaf item $ widgetShow legendDialog
  get castToMenuItem "timeback" >>= \item -> onActivateLeaf item $ history (+1)
  get castToMenuItem "timeforward" >>= \item -> onActivateLeaf item $ history (\x -> x - 1)

  widgetModifyBg canvas StateNormal backgroundColor
  widgetModifyBg legendCanvas StateNormal backgroundColor

  welcomeSVG <- My.getDataFileName "data/welcome.svg" >>= svgNewFromFile

  legendListSVG  <- My.getDataFileName "data/legend_list.svg" >>= svgNewFromFile
  legendGraphSVG <- My.getDataFileName "data/legend_graph.svg" >>= svgNewFromFile

  onExpose canvas $ const $ do
    boxes <- readMVar visBoxes

    if null boxes
    then renderSVGScaled canvas welcomeSVG
    else do
      runCorrect redraw >>= \f -> f canvas
      runCorrect move >>= \f -> f canvas
      return True

  onExpose legendCanvas $ const $ do
    state <- readIORef visState
    renderSVGScaled legendCanvas $ case T.view state of
      ListView  -> legendListSVG
      GraphView -> legendGraphSVG

  setupGUI window canvas legendCanvas

fileSave :: FileChooserDialog -> ResponseId -> IO ()
fileSave fcdialog response = do
  case response of
    ResponseOk -> do Just filename <- fileChooserGetFilename fcdialog
                     mbError <- export' filename
                     case mbError of
                       Nothing -> return ()
                       Just error -> do
                         errorDialog <- messageDialogNew Nothing [] MessageError ButtonsOk error
                         widgetShow errorDialog
                         onResponse errorDialog $ const $ widgetHide errorDialog
                         return ()
    _ -> return ()
  widgetHide fcdialog

newFilter :: FileChooserClass fc => String -> String -> fc -> IO ()
newFilter filterString name dialog = do
  filt <- fileFilterNew
  fileFilterAddPattern filt filterString
  fileFilterSetName filt $ name ++ " (" ++ filterString ++ ")"
  fileChooserAddFilter dialog filt

renderSVGScaled :: (WidgetClass w) => w -> SVG -> IO Bool
renderSVGScaled canvas svg = do
  E.Rectangle _ _ rw2 rh2 <- widgetGetAllocation canvas
  win <- widgetGetDrawWindow canvas
  renderWithDrawable win $ do
    let (cx2, cy2) = svgGetSize svg

        (rw,rh) = (fromIntegral rw2, fromIntegral rh2)
        (cx,cy) = (fromIntegral cx2, fromIntegral cy2)

        -- Proportional scaling
        (sx,sy) = (min (rw/cx) (rh/cy), sx)
        (ox,oy) = (rw/2 - sx*cx/2, rh/2 - sy*cy/2)

    translate ox oy
    scale sx sy
    svgRender svg
#endif

-- Zoom into mouse, but only working from (0,0)
-- newPos = ( oldPosX + x * zoomRatio s - x * newZoomRatio
--          , oldPosY + y * zoomRatio s - y * newZoomRatio )

-- Zoom into center:
-- newPos = ( oldPosX * zoomIncrement
--          , oldPosY * zoomIncrement )
