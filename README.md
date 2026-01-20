# Fidelitty

### A library to render images and stream video in the terminal

This library uses zig ```0.15.2```, with C bindings available. Currently only Linux is supported.

Support for Kitty, ... // TODO: figure out which ones are supported (low prio)

Note that this code is in an early development phase, so expect frequent and significant changes to the API and backend.

#### Features

// TODO: fill out once API solidified, dependencies are factored out. 

- Stable algorithm to compress image patches to background/foreground-colored unicode characters
- 60 fps
- May attach to existing Vulkan backend to redirect out ot the terminal, or create a standalone Vulkan instance.

// Major TODO: allow dynamic font checking and caching of baked binary

#### Installation and building

Install Zig and Vulkan, and ensure proper drivers are installed using ```lspci | grep -A 3 VGA```.

Clone the repo:
```bash
git clone https://github.com/aaronbanse/fidelitty.git
cd fidelitty
```
Generate the unicode dataset and compile main executable with dataset embedded.
```bash
zig build gen-dataset && zig build

```
To run: 
```bash
zig build run
```

#### Algorithm overview

##### Output Format

While Kitty allows for high-resolution image rendering using their protocol, this tool attempts to provide a method for image rendering targeting a more wide range of terminals.
Most modern terminals allow for setting the foreground and background colors of characters using escape sequences, and we use this as the foundation for the algorithm.

While one can turn down the font size to the minimum in order to get a higher resolution image using the full-block character ```0x2588``` or a 2-colored half-block unicode character ```0x2580```, this makes the image renderer unusable alongside other text-based terminal apps. This defeats the purpose of integrated terminal graphics, as you would be better off just opening another window with a real graphics API. 

Hence, we are restricted to rendering images without changing the font size. On my terminal with font size 10, I can fit about 1000 characters ('pixels') on the screen. Using half-block characters with foreground and background color set, we can double the resolution to 2000 pixels. This isn't terrible, but we can do better.

While we can't increase our 'color resolution' (the number of distinct colored patches we can fit on the screen) past 2000 pixels, since we are limited to setting the foreground and background color for a given character, we *can* increase the 'shape resolution'.

##### Patch Matching

The main idea of this algorithm is to render our 'virtual' image to a higher resolution then the effective terminal resolution, say 4000x4000. This gives us a 4x4 patch of pixels for each character in the terminal window. We then assign a pair of colors and a character to each patch that best matches the patch visually.

But how? 

We need to get some help from our dear friend **linear algebra.**

// TODO: Add the proof in latex format

### Data Sizing Conventions

- Pixel color: ```u8```
- Unicode codepoints: ```u32```
- Patch-space / patch dimensions: ```u8```
- Image-space: ```u16```

