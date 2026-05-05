Right now this repo is mostly a POC that may evolve into a game idea.

We are currently focused on trying to build out a solid architecture for a game loop with a semi hand rolled renderer based on zgpu.

For the renderer layer I want the API for it to be inspired by the raylib API.
We should follow more 'zig conventions' where applicable but we should broadly try to match up 
with the raylib API in terms of what measurements and semantics are used for its render functions.

We are trying to use https://github.com/zig-gamedev as much as we can. If we need to add a new feature
That we don't currently have a library or module for check their libraries to see if anything they
offer can help us out.
