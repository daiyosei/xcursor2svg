# xcursor2svg

Please note that Generative AI was used for making this project

In GNOME >=51, it is now required to use only svg based cursor as xcursor got deprecated
now, I didn't want to give up on my xcursor themes, which were drawn by artists and not
something rasterized, what this script does is it takes each pixel of the original cursor
and draws a svg pixel-by-pixel, I think desktop environment like GNOME and KDE cache the
svg into bitmap, so having a thousand rectangles in a few hundred frame wont cause any
performance issue. (atleast I hope so, idk I didn't check this).

I tested this on [Hatsune Miku cursor theme by
supermariofps](https://github.com/supermariofps/hatsune-miku-windows-linux-cursors) and a
few other legacy xcursor themes. It worked pretty well for me on GNOME 51. Please open a
Pull request or submit an issue if something goes wrong. Thank you ^^

> [!IMPORTANT]
> This project requires `xcur2png` and `imagemagick` which you can find in your standard distro
> repos.

## Usage : 

```bash
./xcursor2svg.sh --res 64 ~/.icons/miku-cursor-linux # install from a old xcursor theme
./xcursor2svg.sh --res 64 -y /path/to/theme # Convert and install automatically
./xcursor2svg.sh --res 64 -n /path/to/theme # Convert only
# For a theme already installed in a standard icon directory:
./xcursor2svg.sh --res 64 miku-cursor-linux
```

`--res` sets the nominal cursor size (default: 32). For each cursor, the closest
available Xcursor size is selected, preferring the larger size in a tie. All
frames at that size are resized with nearest-neighbor sampling. Visible pixels
become SVG rectangles with their original colors and transparency. A source at
the requested size keeps its pixels exactly; resizing replicates or drops pixels,
without smoothing. These SVGs retain the bitmap appearance when scaled.

Animation order, delays, hotspots, and aliases are preserved in
`cursors_scalable/`, with missing GNOME/CSS names filled from legacy equivalents.
The original `cursors/` directory is copied for legacy applications. Canvas
dimensions and hotspots scale together; cropped or rectangular source cursors
are not stretched into squares.
