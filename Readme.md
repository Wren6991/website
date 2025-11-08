# wren.wtf

This is the source code for [wren.wtf](https://wren.wtf).

## Dependencies (Ubuntu)

```bash
sudo apt install pandoc codespell
```

## Dependencies (MacOS)

On MacOS:

```bash
brew install findutils gnu-sed pandoc codespell
```

You'll also need GNU `find` and `sed` to be first on your PATH.

## Building

To generate the website into `build/`:

```bash
make
```

To serve the website locally (you must have `python3` installed):

```bash
make serve
```

Visit `http://localhost:8000/` in your web browser to view the local copy of the website.

If you are me then you can `scp` the `build/` directory onto the server using:

```bash
make deploy
```
