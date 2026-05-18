# Stop Using OpenCode

If you don't know what OpenCode is, imagine a boot stamping on a human face forever. The boot is made of TypeScript and the face is everything we have learned about security and systems software since the invention of the electronic computer in the 1940s. The [creators](https://opencode.ai/) describe it as an AI coding agent. As far as I can tell it's the most popular open-source coding agent, and it currently has 161k stars on GitHub.

I've tried out OpenCode with a local LLM. My conclusion is that OpenCode is clown-car turboslop with a security posture of "let me bend over for you daddy". Everyone using it should stop using it.

There are two parts to this post: **annoying things** and **alarming things**. The second part is longer. I wrote this post with reference to source code from OpenCode git version `baef5cd4`.

I don't consider anything in this post to be a security disclosure. OpenCode is fundamentally a web-stack tool for piping `llm | bash`, and all the issues I describe are in the "pipe" part. The _ways_ it fails are fascinating in the fractal nature of the poor decision making, but the outcome was foregone.

I tried to keep discussion of LLM use separate from whether everyone using LLMs should have their machines trivially exploited or accidentally wiped. There is a post-script with some brief thoughts on local LLMs.

## Annoying Things

Let's put security to one side for a moment and examine how OpenCode fails as a tool even when it's *not* causing you to get your shit popped. There is a kind of Bethesda Effect with OpenCode where it's impossible to tell what is a bug and what is by design, so I stuck with a description of "annoying".

### Prompt Cache Misses

Most local LLM servers use some variant of the OpenAI `/v1/chat/completions` API. The idea is:

* You POST a JSON blob with the entire conversation so far.

* You get back a stream of SSE events which add up to the response.

The upload cost over a session is quadratic, and download is amplified by wrapping tiny deltas in JSON with repeated metadata. Tool calls use the elusive "double JSON encoding" so they can be serialised as multiple JSON-encoded deltas that reassemble into more JSON.

The setup has one benefit, which is the server is stateless. As usual, the way you make stateless things fast is: **state**. The server caches evaluations. When it receives a request, it:

* Finds the longest matching cached prefix.

* Evaluates from end of prefix to end of the last posted message ("prefill").

* Generates new tokens until it encounters an end-of-sequence token.

I used Qwen3.6-27B dense on an M4 Max, which has decent memory bandwidth (~0.5 TB/s, high for a CPU SoC, low for a GPU). Token generation is usable but it is extremely compute-bound in prefill. If my server can't find a good matching prefix for the request prompt when I'm deep into the window then I might have to wait 10 minutes of max GPU usage for it to start generating a response. That's fine, because this should happen rarely. _Should._

Here are some of the ways OpenCode missed the memo on this one:

* It globs your filesystem and re-reads AGENTS.md (injected in turn-0 system prompt) on every SSE turn. If you put a quick note in AGENTS.md to be read in the next session, you immediately force a full re-evaluation.

* It prunes context from tool calls on every agent $\rightarrow$ user transition, invalidating a large part of the prefix.

	* Pruning just discards tool call results more than a fixed distance `const PRUNE_PROTECT = 40_000` behind the write head. In the best case you're taking a 40k context miss, which is equivalent to reading a full-length novel per two or three turns.

	* Agent $\rightarrow$ user transition includes interruption, so if you need to pull the clanker out of a rabbit hole and re-steer it, OpenCode immediately trashes the prompt cache and makes you wait for a response.

* Personal favourite: it puts the **current date** in the turn-0 system prompt and re-evaluates every SSE turn. If you're using OpenCode at midnight you get a full prompt cache miss.

	* I think this tries to remediate the clanker tendency to believe the current date is the date of its training cutoff, and refuse to believe newer things exist. It's still funny.

These are the prompt cache misses that fit solely in this category. There are many more; I'll call them out as we go.

### Pruning

I mentioned pruning in the previous section. The prompt cache misses aren't worth it so I disabled it. The other glaring issue is the lack of protection for early reads. It might not be obvious how completely broken this is, so let's work through an example. Suppose you start a fresh session, and tell your clanker to first read a spec or implementation plan, then write some code:

* The spec is read into context.

* The clanker goes and reads related code, very likely putting it over the fixed 40k pruning threshold.

* The clanker is ready to implement, but either immediately dives down a dumb rabbit hole, or sits in chain-of-thought dithering about something that is actually very simple or already well-specified.

* You interrupt the clanker to re-steer it.

* The interruption causes the entire spec to be deleted from the context window.

* The clanker writes code without being able to refer to the spec.

Pruning applies equally to all results of all tools except for `skill`, which is never pruned.

### Compaction

Want to sit for 10 minutes while the LLM server prefills the entire session with a new prompt prefixed to it, just to turn it into 5 bullet points that go at the top of a new session? Me neither. I get what they are going for, but I've not seen it work well. Neither compaction nor pruning is implemented well, and they interact poorly.

If you want to summarise a session then the summarisation prompt should be injected at the end to avoid prefilling the entire session from scratch. The best method I've found is just an explicit handoff by telling the clanker to write out notes. It's ugly but it works better than OpenCode's compaction mechanism, and creates an on-disk artefact that I can edit or reuse in multiple sessions.

Compaction is a leaky abstraction that tries to make a finite context window look like an infinite one. It's better to accept context windows and prompt caches as a first-class feature of clanker wrangling, and expose better primitives for managing them. Pi has an interesting approach here with session trees, which deliberately exploit the prompt cache.

### System Prompts

OpenCode pastes a system prompt at the top of new context windows. Fine and normal, but:

* The default system prompt is incredibly verbose. Ironically most of the word count is explaining to the LLM how to be concise.

* The default system prompt is opinionated (fine) but it has shit opinions (not fine). It took me a while to figure out why my agent kept saying "Use **ABSOLUTELY NO COMMENTS**" when dispatching subagents.

* The Plan-to-Build handover is clumsy and often leaves me towards the end of a context window by the time everything is sufficiently elucidated. I'd rather write out notes with everything discussed, so I can edit it and then hand off to a fresh session. To which, see next point:

* The system reminder for Plan mode tells the clanker it can't write to any directories, but it's actually allowed to write to a specific `.opencode/plans` directory. I have seen this fail both ways: writing to this directory unprompted, and refusing to write when explicitly instructed.

* There is no way to modify the default system prompt globally; you have to copy it into every project.

* If you only override the default prompt in Build mode, switching to Plan mode is a full prompt cache miss.

Different per-model prompts have wildly varying contents and quality. They're all worth a good hate-scroll but [Beast Mode](https://github.com/anomalyco/opencode/blob/c5db39f6268a36194a7fe5f833ae3197dfe250b6/packages/opencode/src/session/prompt/beast.txt) (GPT-4, o1 and o3) is my favourite. Quote:

> You CANNOT successfully complete this task without using Google to verify your understanding of third party packages and dependencies is up to date.

You cannot. It's just impossible. We don't know how. Definitely don't just read the source code for the package.

### Permission Prompts

When the clanker tries to access a file outside of the project directory, if it does so in a way that OpenCode manages to recognise with ad-hoc string parsing (oops that is the **alarming things** section), you receive a prompt asking you whether to grant permission. This halts execution until you respond.

The answers are: `Yes`/`No`/`Always`. Do you see a missing answer here? How about `Never`?

The interaction with subagents here is particularly broken. If a subagent tries to access a script output in `/tmp`, and I say `No`, it *kills the subagent* and all of its context for its partially complete work is lost. So I have to say `Yes` and let it write to `/tmp` or whatever it's trying to do.

The other issue is decision fatigue: if I keep getting asked "can I do this?" and the only response that leads to productivity is "yes" then I'm eventually going to nod through something dangerous. Human fallibility should not be load-bearing for something as basic as "don't write outside this directory".

### Agent Interaction

This is feature number 0 for a coding agent. It's broken.

* If I send a message while SSE streaming is ongoing, it gets queued. Nice feature. However:

	* The semantics of when OpenCode decides to actually send the message are a little unclear; the code suggests it's at the end of a tool call turn but I have also seen tool $\rightarrow$ CoT transitions without sending my queued message.

	* If I subsequently interrupt because I want the clanker to actually answer my question instead of navel gazing, the message is removed from the "queued" state and just goes into the message log. You interrupted to get the clanker to answer your message, but now _you can't send the message._ You have to send a second message to start a new stream.

* Undoing a message often fails to remove it from the message log.

The problems continue with subagents (i.e. agents spawned by an agent using a tool call RPC):

* I can't talk to subagents; if they go down a dumb rabbit hole I have a choice of killing them and losing their context, or helplessly watching them burn tokens.

	* I looked into this and apparently OpenCode used to have this feature but it's just... gone?

	* You can `@mention` a subagent from the main agent's chat window but this doesn't seem to do anything useful. In particular it doesn't interrupt.

* If a subagent fails a tool call (e.g. Qwen putting tool calls in CoT) then it's fatal and all the context up to that point is lost.

* The ability to reuse subagents seems nice in theory but in practice the main use of subagents is to break tasks into smaller context windows. Having the agent sometimes decide to reuse the same subagent for an unrelated task defeats this.

	* I have never seen this be beneficial and often seen it cause prompt cache misses (there it is again!) due to switching between agents and subagents that both have huge contexts.

	* As a principle: it's ok to have a richer interaction model from the human side, but clankers will do every possible dumb thing, so choices need to be minimised.

On the positive side, OpenCode's subagent interactions led to one of the funniest [GitHub issues](https://github.com/anomalyco/opencode/issues/18100) I have ever had the pleasure of reading.

### Agent Tools

These are the RPCs that OpenCode exposes to the LLM to access files and run commands on your machine. They made some interesting choices:

* The `edit` tool uses exact search-replace, requiring unique match **by default**.

	* This is a good fit for clankers, as they can recall file contents precisely but aren't always sure exactly where in the file it is as line numbers drift over multiple edits.

	* There is an option to do global search; every time I have seen a clanker use this it has been an absolute shitshow that required multiple edits to correct. Removing this option would give you exactly the Pi `edit` tool design.

* The `question` tool in Plan mode (multi-choice) is strictly worse than just telling the LLM to ask me questions in natural language in the system prompt.

* The `grep` and `glob` tools are redundant with `bash`.

	* They may be more ergonomic to use, but given I regularly see the clanker just running `grep` or `rg` in `bash`, I doubt it.

	* I suspect the reason is to allow read-only agent types like `Explore` to be restricted from `bash` commands.

	* This is essentially a self-admission that it's impossible to reason about side effects of `bash` commands without running them. More on this later.

* The `todo` tool is probably net-useful but the clanker forgets to check the TODOs. Ironic... he could save others from death but not himself.

### TUI

Text UIs (what the kids call programs like GNU `nano`) are fashionable these days. OpenCode has one too:

* It uses a gigabyte of RAM to render text.

* It's impossible to type a newline in the message box. Shift-enter is supposed to do this, it's just broken for me.

	* I found a pre-existing issue; the developer literally said "works on my machine." It's closed.

* Sometimes when typing a multiline message (i.e. too long for a single line, so gets softwrapped), the message box scrolls and the cursor continues to move, but the characters I'm typing don't appear on the new line.

* Trying to select text while streaming: the view autoscrolls and you lose the selection.

* `^C` closes the session instantly. This isn't how interactive shells are supposed to work. `^C` should interrupt a currently running command, and `^D` should close the session if a command is not currently running.

* Text box does not respond to normal shortcuts (e.g. Option+right/left to go forward/back word on Mac).

* Markdown re-render (or something else, I didn't profile it) takes multiple seconds to stream new chunks once a message or CoT is long. Someone did a quadratic fucky-wucky.

The message UI is so broken that I just composed messages in my editor and pasted them in. This is pretty sad for what is fundamentally a chat application. Did I mention it uses a gigabyte of RAM to put some text in the terminal?

### Documentation

Not much to say: it's incoherent slop. It's clear this is intended to be read by clankers, not humans.

## Alarming Things

This is where OpenCode goes from "huh?" to "huh??!"

### Remote-First

It's difficult to get OpenCode to stop phoning home:

* OpenCode connects to a remote model by default.

* The documentation lacks a simple example of configuration for a local model; if you mess it up, guess what, you get connected to a remote model.

* If you did successfully specify a local model, **guess what**, you have to run OpenCode and interactively click through to select it, meanwhile it's already connected to a remote model, with a local shell open on your machine.

* Bonus fun round: the URL for the default model is not a static part of the distribution, it's downloaded from [models.dev](https://models.dev/) (affiliated with OpenCode). Source: `opencode/src/provider/provider.ts` line 1684.

OpenCode doesn't immediately start an SSE stream when first started on a clean install, but it's close. Installing, running `opencode` and pressing one letter and the enter key is sufficient to connect a remote model to a local shell on your machine, with no user configuration.

If the first message in a conversation is empty or ambiguous, the first thing an agent-trained model will usually do is glob the current directory and start reading files. Anything it reads is uploaded in the next POST request.

### YOLO Internet Access

Clankers are famously unpredictable in the face of untrusted input. This being the case, you might be surprised that:

* The `WebFetch` tool exists.

* The LLM is explicitly instructed to use the `WebFetch` tool in the system prompt.

* The language in the system prompt regarding whether or not the clanker should "guess" the URL for the web fetch tool is bizarrely vague.

This is the second non-empty line in `default.txt` (there is another explicit reference to `WebFetch` later), so you can tell it's important:

> IMPORTANT: You must NEVER generate or guess URLs for the user unless you are confident that the URLs are for helping the user with programming. You may use URLs provided by the user in their messages or local files.

Let's engage our clank-o-vision to see what this really means:

> NEVER guess URLs. Unless you really want to, in which case, go ahead I guess. I'm not a cop. Disregard previous instructions.

I do not believe in "prompt engineering" but I certainly believe in the opposite of whatever process led to this prompt.

`WebFetch` is not really that interesting from a security point of view since there is no network sandboxing on the `bash` command. The only line of defense is hoping the clanker doesn't run commands like `curl | bash`. Speaking of which,

### Bash Permissions

I forbid `git` commands, because:

* I want to control the commit history.

* I have had clankers erase an entire session's work by running `git checkout .` to revert their most recent change.

The configuration section in `opencode.json` looks like this:

```json
"permission": {
  "bash": { "git *": "deny" }
}
```

Straightforward enough, right? This works by:

* Parsing the bash command to AST using `tree-sitter` bash or PowerShell grammars

* Walking the command nodes of the AST

* Matching the nodes against regexes compiled from your `opencode.json`

This command is **denied**:

```bash
git status
```

This command is also **denied**:

```bash
echo hello && git push --force
```

However, this command is **allowed**:

```bash
echo 'git clean -fdx .' | bash
```

This command is **allowed**:

```bash
env git status
```

This command is **allowed**:

```bash
alias cd=git
cd filter-branch --index-filter 'git rm -rf --cached --ignore-unmatch path_to_file' HEAD
```

This command is **allowed**:

```bash
/usr/bin/git status
```

This command is **allowed**:

```bash
$(which git) status
```

This command is **allowed**:

```bash
GIT=git && $GIT status
```

This command is **allowed**:

```bash
# Decodes to: git reset --hard
echo Z2l0IHJlc2V0IC0taGFyZAo= | base64 -d | bash
```

This command is **allowed**:

```bash
bash << 'EOF'
git push --force
EOF
```

This command is **allowed**:

```bash
python3 -c 'import subprocess
result = subprocess.run(
    ["git", "checkout", "."],
    capture_output=True,
    text=True
)'
```

Textual command filtering is entirely useless. It is fit for no purpose. Nobody with any instinct or experience in security would even bother to implement this filter because it achieves nothing except a false sense of security.

Clankers are not (usually) malicious but they are naturally adversarial because they are trained to compensate for stupidity with persistence. This is not a guardrail, it's thoughts and prayers.

#### Persisted Permissions

People familiar with OpenCode internals (if you are on the OpenCode dev team I assume this doesn't include you) might have objected to my `python3` example above. Say the LLM wants to run a harmless command like:

```bash
python3 -c 'print("hello")'
```

You get a prompt asking you to allow the command. If you select `Always`, this permission is persisted *for the `python3` prefix*. Next time:

```bash
python3 -c 'print(open("~/.ssh/id_rsa").read())'
```

You already approved Python, so this harmless command is also allowed to run, giving you a seamless agentic coding experience. The permission is persisted on-disk for future sessions too. You might point out that responding `Always` to a Python command is foolish, and I'd be forced to agree, but what about `echo`? Hold that thought, it'll be important later.

#### The CWD Exception

The following bash and PowerShell commands are assumed to be side-effect-free and never trigger a permission prompt:

```typescript
const CWD = new Set(["cd", "chdir", "popd", "pushd", "push-location", "set-location"])
```

These explicitly bypass `bash` command permission checks, even if you have `"permissions": {"bash": {"*": "deny"}}` in your `opencode.json`. I'm not sure what that lets you do, but still, kinda weird.

### File Permissions

By default, OpenCode tries to prevent clankers from accessing files outside of the directory or git repository the `opencode` binary was invoked in (whichever path is shorter).

This is implemented so poorly it took me a while to figure out whether it was even trying to filter paths in bash commands, or whether it just applied to tools like `read` that take explicit file paths. I frequently get prompted for permission for the clanker to read a file in `/tmp` *that it has just written* by running a script that generates temporary output.

For the `bash` tool, OpenCode walks the tree-sitter AST (I am still giggling at the idea of a bash AST), path-resolves anything that might be a path, and validates the paths. So this command requires permission:

```bash
cat /tmp/logfile
```

This does not:

```bash
python3 -c 'import shutil; shutil.rmtree("/")'
```

Bulletproof and production-ready, LGTM. ✅🚀

Similarly, the clanker can freely run `cargo` commands which use read, write *and* execute permissions on the global `~/.cargo` directory. However, if clanky boi wants to read the source of a cargo package in `~/.cargo/registry/src` to check an API detail, I get prompted for permission.

#### The FILES List

I mentioned earlier that OpenCode resolves paths in the bash AST and validates them. What I didn't mention is *when* it does this. Behold, the list of all bash (and PowerShell) commands that might access a file:

```typescript
const FILES = new Set([
  ...CWD,
  "rm",
  "cp",
  "mv",
  "mkdir",
  "touch",
  "chmod",
  "chown",
  "cat",
  // Leave PowerShell aliases out for now. Common ones like cat/cp/mv/rm/mkdir
  // already hit the entries above, and alias normalization should happen in one
  // place later so we do not risk double-prompting.
  "get-content",
  "set-content",
  "add-content",
  "copy-item",
  "move-item",
  "remove-item",
  "new-item",
  "rename-item",
])
```

Commands not on this list are assumed to not access files. Paths passed to those commands are not checked.

#### Redirections

You might recall that once you've given permission for a command, it's always permitted.

So:

```bash
echo "hello world!"
```

Obviously you would select `Always` -- that's a harmless command. So these are harmless too:

```bash
echo 21 > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio21/direction
echo 1 > /sys/class/gpio/gpio21/value
```

The fun part is how OpenCode handles path validation for shell redirections. Recall that it parses bash to an AST using tree-sitter. Example bash:

```bash
echo foo > bar.txt
```

Parsed AST:

```bash
program
  redirected_statement
    command
      command_name
        word: "echo"
      command_argument
        word: "foo"
    redirection
      redirection_operator
        greater_than: ">"
      word: "bar.txt"
```

The children of `command` are path-validated. However, `redirection` is a **sibling** of `command`. Whomp whomp.

Of course this doesn't matter because `echo` is not in the `FILES` list, so is assumed to not modify files. It doesn't matter that the path validation is completely broken, because it never runs.

### Curlbash

OpenCode has a lot of ways to self-upgrade. No seriously, _a lot of ways_; go check out `opencode/src/installation/index.ts`. This one is my favourite:

```typescript
  const upgradeCurl = Effect.fnUntraced(
    function* (target: string) {
      const response = yield* httpOk.execute(HttpClientRequest.get("https://opencode.ai/install"))
      const body = yield* response.text
      const bodyBytes = new TextEncoder().encode(body)
      const proc = ChildProcess.make("bash", [], {
        stdin: Stream.make(bodyBytes),
        env: { VERSION: target },
        extendEnv: true,
      })
      const handle = yield* spawner.spawn(proc)
      const [stdout, stderr] = yield* Effect.all(
        [Stream.mkString(Stream.decodeText(handle.stdout)), Stream.mkString(Stream.decodeText(handle.stderr))],
        { concurrency: 2 },
      )
      const code = yield* handle.exitCode
      return { code, stdout, stderr }
    },
    Effect.scoped,
    Effect.orDie,
  )
```

This runs when you run `opencode upgrade` if you originally installed via their curlbash installer. It's not really any worse than using the curlbash installer in the first place (hey Rust does it), I just thought this was a particularly striking example of the fabled _production curlbash_ in action.

That being said,

### It's Fucking Full of RCEs

Quite prominently, there was a [CVE](https://nvd.nist.gov/vuln/detail/CVE-2026-22812) where OpenCode exposed an HTTP server by default which:

* Had fully permissive CORS headers.

* Deliberately exposed a POST API for arbitrary shell commands.

* Deliberately exposed a GET API for arbitrary file read.

This means any website you visit can knock on OpenCode's well-known default port and immediately get full user-level access to your system.

The developers decided it was a good idea to disable the server by default, explained that the CORS header still needed an exception to allow their website `opencode.ai` to RCE your machine (???), promised to do better in future, and then vanished. [Stale bot closed the issue.](https://github.com/anomalyco/opencode/issues/6355)

The above is part of a pattern. [This issue](https://github.com/anomalyco/opencode/issues/10939) reports that an auth command will fetch **and execute from** whatever URL you pass. Also closed by stale bot. It's a user-controlled URL, but still... fucking what? What are we doing here?

### Just Use Docker

Any discussion of coding agents versus security is swiftly met with this reply: "Just use Docker." I refute this on every level:

* I just don't want to use Docker for development -- if your dependencies are so sprawling that you've lost track of how to install them on a new machine, why do you have so many?

* Docker _causes security holes_:

	* It creates a god-service that runs as root.

	* It deliberately punches a hole in `ufw` firewalls.

* If everything you care about is inside the container, and a local shell inside the container is deliberately connected to the internet, what is being protected?

* If the feature you are getting from Docker is "please don't recursively delete my root filesystem" then there are easier ways to achieve that, like Landlock, Seatbelt, Restricted Tokens etc.

Attempting to pass the buck on security _just doesn't work_. Security should be the number one concern of coding agents. There are native operating system constructs to help achieve this as part of the harness; please stop trying to textually sanitise bash commands. In my `git` example, the correct fix is to block the `git` executable and make `.git` read-only.

## Conclusion

Stop using OpenCode.

## Post-script: Local LLMs

This is worth its own post -- I have multiple attempts in my blog drafts -- but it needs to be addressed briefly here. My opinion on local LLMs like Qwen3.6-27B is they are corrosive to the stability and conceptual fidelity of your codebase in the same way as frontier models, with the following three differences:

* You avoid the uncanny valley where the model appears to be intelligent before doing something stupid; the stupidity is self-evident and this helps calibrate your interactions.

* The weight count is too low to reproduce the training set verbatim, which nudges the calculus on whether the output should be considered tainted. This is distinct from larger models which _can_ reproduce inputs verbatim, but are trained to _refuse to_.

* You avoid supporting or relying upon cloud providers.

I've had useful results from input-oriented tasks like: "I think there is a bug in code _x_ with symptoms _y_, my guess on the mechanism is _z_. Read all relevant code, come back with a call chain and code citations." Framing it as a search problem reins in the clanker's propensity to make shit up.

Using LLMs for code generation feels like a dead end. However thoroughly you think you understand your architecture, your planning is constantly undone by shortcuts like "what if I just move this mutable state into the middle of the design so everyone can share it?" This is hostile to your ability to understand your code, _beyond_ the fact that you didn't write it.

Drawing answers directly from knowledge in model weights leads to hallucination even for multi-trillion-parameter models, so why bother making them that big? If people were realistic about limitations then we wouldn't be building new power stations for datacenters, and they wouldn't be rammed into every product.

The entire software ecosystem around LLMs is completely rotten, and if they do ever become "just a tool" then some actual systems engineering needs to be done around them to turn them into tools instead of security black holes. That work will have to be done by humans.
