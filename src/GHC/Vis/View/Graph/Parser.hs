{-# LANGUAGE OverloadedStrings #-}

{- |
   Module      : GHC.Vis.View.Graph.Parser
   Copyright   : (c) Dennis Felsing
   License     : 3-Clause BSD-style
   Maintainer  : dennis@felsin9.de

 -}
module GHC.Vis.View.Graph.Parser (
  xDotParse
)
where

import Data.Monoid

import qualified Data.Foldable as F
import qualified Data.IntMap as M
import qualified Data.IntSet as S

import qualified Data.Text.Lazy as B

import Data.Graph.Inductive hiding (edges, newNodes)

import Data.GraphViz hiding (toNode, Ellipse, Polygon, parse)
import Data.GraphViz.Attributes.Complete
import Data.GraphViz.Commands.IO

import GHC.HeapView hiding (name)
import GHC.Vis.Internal (showClosureFields)
import GHC.Vis.Types
import GHC.Vis.View.Common

import Graphics.XDot.Types hiding (name, h, Style, Color)
import Graphics.XDot.Parser

fontName :: B.Text
--fontName = "Times Roman"
--fontName = "Helvetica"
fontName = "Sans"

graphFontSize :: Double
graphFontSize = 24

nodeFontSize :: Double
nodeFontSize = 24

edgeFontSize :: Double
edgeFontSize = 24

graphvizCommand :: GraphvizCommand
graphvizCommand = Dot

-- | A generic algorithm to restrict a graph to the subgraph reachable by certain nodes
reachableSubgraph :: DynGraph gr => [Node] => gr a b => gr a b
reachableSubgraph roots graph = flip delNodes graph $
    filter (`S.notMember` reachableNodes) $
    nodes graph
  where
    trGraph = trc graph
    reachableNodes = S.unions $ map (S.fromList . suc trGraph) roots


-- | Converts a 'HeapGraph' to a fgl 'Gr', taking into account special
-- representations for BCOs.
convertGraph :: HeapGraph Identifier -> Gr ([String], Int) (String, Int)
convertGraph hg = appEndo (removeGarbage <> addNames <> addEdges <> addNodes) empty
  where
    HeapGraph hgm = hg

    -- Adds nodes for every closure in the map
    -- Special treatment for BCOs: Use the disassembler
    addNodes = mconcat [
        Endo (insNode (i, toNode hge))
        | (i,hge) <- M.toList hgm
        ]

    deref = fmap $ hgeClosure . (M.!) hgm

    toNode hge | Just byteCode <- disassembleBCO deref (hgeClosure hge)
        -- Does not look nice this way, far too wide
        -- = (map show byteCode, 0)
        = (["BCO"], length (concatMap F.toList byteCode))
               | otherwise
        = (showClosureFields (hgeClosure hge), length $ allPtrs (hgeClosure hge))

    -- Adds edges between the closurs, treating BCOs specially
    addEdges = mconcat [
        Endo (insEdge (i, t, ("",n)))
        | (i, hge) <- M.toList hgm
        , (t,n) <- toEdges hge
        ]
    toEdges hge = [ (t, n) | (Just t, n) <- zip myPtrs [0..] ]
        where myPtrs | Just byteCode <- disassembleBCO deref (hgeClosure hge)
                     = concatMap F.toList byteCode
                     | otherwise
                     = allPtrs (hgeClosure hge)

    -- Adds the nodes and edges for the names
    -- addNameList = zip [-1,-2..] -- Displays from right to left
    addNameList = zip [-1,-2..] $ reverse
        [ (i,name)
        | (i, hge) <- M.toList hgm
        , name <- hgeData hge
        ]
    addNames = mconcat $ map addName addNameList
    addName (n,(i,name)) = Endo (insEdge (n, i, (name, 0))) <> Endo (insNode (n, ([""],0)))

    -- Removes nodes not reachable by a named closure
    removeGarbage = Endo (reachableSubgraph (map fst addNameList))

-- | Take the objects to be visualized and run them through @dot@ and extract
--   the drawing operations that have to be exectued to show the graph of the
--   heap map.
xDotParse :: IO ([(Object Node, Operation)], [Box], [(Object Node, Rectangle)], Rectangle)
xDotParse = do
  --(hg, _) <- multiBuildHeapGraph 100 as
  (hg, _) <- getHeapGraph
  xDot <- graphvizWithHandle graphvizCommand (defaultVis $ convertGraph hg) XDot hGetDot

  return (getOperations xDot, getBoxes hg, getDimensions xDot, getSize xDot)

getBoxes :: HeapGraph a -> [Box]
getBoxes (HeapGraph hg) = map (\(HeapGraphEntry b _ _ _) -> b) $ M.elems hg

defaultVis :: (Graph gr) => gr ([String], Int) (String, Int) -> DotGraph Node
defaultVis = graphToDot nonClusteredParams
  -- Somehow (X11Color Transparency) is white, use (RGBA 0 0 0 0) instead
  -- Ordering OutEdges is not strong enough to force edge ordering, might not look good anyway
  { globalAttributes = [GraphAttrs [BgColor [toWC $ RGBA 0 0 0 0], FontName fontName, FontSize graphFontSize]]
  , fmtNode = \(x,(l,i)) -> if x >= 0 then [
        --xLabel (B.pack "foo"),
        nodeLabel l i,
        Shape Record, FontName fontName, FontSize nodeFontSize]
      -- x < 0: Invisible marker nodes
      else [Shape PointShape, Style [SItem Invisible []]]
  --, fmtNode = \ (_,l) -> [toLabel l, FontName fontName, FontSize nodeFontSize, Style [SItem Filled []], FillColor [RGBA 255 255 255 255], Color [RGBA 0 0 0 255]]
  --, fmtNode = \ (_,l) -> [toLabel l, FontName fontName, FontSize nodeFontSize, Shape PlainText]
  , fmtEdge = \ (_,_,(l,i)) -> [
        TailPort (LabelledPort (PN (B.pack (show i))) Nothing),
        toLabel l,
        FontName fontName, FontSize edgeFontSize]
  }
  where
    {-
    All pointer origins below the constructor:
    nodeLabel l 0 = Label $ RecordLabel [FieldLabel (B.pack l) | l <- ls]
    nodeLabel l i = Label $ RecordLabel [
            FlipFields [
                FlipFields [FieldLabel (B.pack l) | l <- ls] ++
                FlipFields [PortName (PN (B.pack (show j))) | j <- [0..i-1]]
            ]]
    -}
    {-
    All pointer following the constructor on the right:
    -}
    nodeLabel ls i = Label $ RecordLabel $
                [FieldLabel (B.pack l) | l <- ls] ++
                [ PortName (PN (B.pack (show j))) | j <- [0..i-1]]
