# bezier-triangles

This is a rewrite of an old art project. It reflects some lessons I learned over the last few months.

The original version was done in Fall 2022. It was written in Rust and used an off-the-shelf rendering engine. It took me something like 4 days of almost non-stop work, plus a few days trying to fix undesirable visual bugs that I eventually gave up on and left in.

This version uses the Vulkan API directly. It took me about 14 hours of work.

### Why was the harder method so much faster to write?

1. The obvious: the first time, I had to mess around with the visuals and simulation and figure out what I was actually making. This doesn't help the point I'm trying to make, but it did save me a lot of time.
2. Practice.
   - My programming experience before the original project was small class projects and single-file personal projects. At the time, this was probably the hardest thing I'd done. Since then I'd spent a semester focusing full-time on larger personal projects, and I've spent the last few months writing a videogame from scratch. Building something big without frameworks to glue together builds skill and confidence that you don't get from small, time-constrained assignments.
   - This is my third time (successfully) writing a Vulkan application. The first time was mostly copy-pasting from a tutorial, and I had no idea what I was doing; the code was littered with "what the hell does this mean?" comments and incorrect explanations, and my own added components were relatively small. The second time was my videogame, where I started from scratch again; this time with a small amount of prior experience, no deadline, and a focus on understanding the API so that I could use it for my specific needs. That took me from slow and confused to comfortable over a few months. And this third time, it was almost second nature; I still learned a couple things, but the learning itself also got easier because of all the context and background I'd built up.
3. Low-level stuff isn't really scary. Specifically, Vulkan (eventually) isn't that bad. The basic needs of many programs are similar (initialization, update-render-present loop, window resizing...). Once you've written a sizeable Vulkan program that you understand, you can copy-paste and modify large swathes of boilerplate to fit your needs, both between projects and within a project.

### Why tho

I heard Asaf Gartner say roughly this on the Handmade Network Podcast:
> I'm not sure Javascript was ever actually the bottleneck. But people tend to do very inefficient things in Javascript, so it appeared to be the bottleneck.

And he's right! I've seen some pretty neat [Python](https://github.com/kovidgoyal/kitty) [programs](https://github.com/Rafale25/Boids-Moderngl) where performance matters 
(granted, they may use libraries written in other languages). And I've written some really slow Rust programs, despite Rust being *:rocket: blazingly fast :rocket:*.

The original version of this project had a bunch of moving Bezier curves with trails. I wanted to create the trails by tracking and rendering previous positions of the curves, but I was computing all the line-segment positions in one thread and telling a library to render each one individually, every frame. (I was probably also doing stupid shit with memory; didn't commit to Git history, can't check). My laptop could not keep up, so I resorted to an alpha-based hack that left ugly artifacts on the screen if you looked closely. You couldn't resize the window, and the visuals glitched out if you fullscreened it or enabled vsync. I had no way to address the latter glitchiness other than to use a large non-fullscreen window and disable vsync.

None of those problems are in this version.

Regardless of the language,
1. Writing a good program requires a decent understanding of what's going on under the hood.
2. Restricting yourself to some "no-effort" framework's API can prevent you from controlling your program; accessing the under-the-hood APIs directly is like gaining superpowers.

I got into a brief conversation about this and thought that rewriting my own shitty program would be a good demonstration. It was also good practice for me.

---

As an aside: I haven't explicitly demonstrated a performance improvement here. I encountered a cool visual bug and decided to keep that instead of implementing trails, and I realized that "offloading work to a GPU improves performance" isn't a controversial statement anyway. This *does* demonstrate that accessing the GPU directly isn't that hard.

Unrelated, [here's the art](https://www.youtube.com/watch?v=r5iFEGc0I90).
