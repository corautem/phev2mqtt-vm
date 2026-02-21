# GitHub Copilot Pro+ Setup Guide

## For the phev2mqtt Web UI Project

---

## Is Awesome GitHub Copilot Worth It For This Project?

**Yes — specifically for two things:**

1. **The `copilot-instructions.md` file** keeps every file Copilot generates consistent with your architecture, security rules, and stack choices — without you re-explaining them every session
2. **The Python instructions** from the Awesome Copilot repo give Copilot solid Python/Flask best practices out of the box

Everything else in the Awesome Copilot repo (agents, hooks, chat modes) is useful for large teams but overkill for a solo project. This guide focuses on what actually matters for you.

---

## Part 1 — Prerequisites

Before anything else, make sure you have:

- **VS Code** installed — [download here](https://code.visualstudio.com/)
- **GitHub Copilot Pro+** subscription active on your GitHub account
- **Git** installed and configured
- A **local project folder** created for the phev2mqtt web UI (even if empty)

---

## Part 2 — Install GitHub Copilot in VS Code

**Step 1.** Open VS Code

**Step 2.** Click the **Copilot icon** in the bottom status bar (looks like the GitHub Copilot logo), then select **"Set up Copilot"**

**Step 3.** Choose **"Sign in with GitHub"** and follow the browser prompts to authorise VS Code with your GitHub account

**Step 4.** Once signed in, VS Code will detect your Pro+ subscription automatically — you'll see the Copilot icon become active in the status bar

**Step 5.** Verify it's working: press `Ctrl+Alt+I` (Windows/Linux) or `Ctrl+Cmd+I` (Mac) to open the Copilot Chat panel. Type "hello" — if it responds, you're set up correctly

---

## Part 3 — Set Up Your Project Folder

**Step 1.** Open VS Code and open your project folder:
`File → Open Folder → select your phev2mqtt-webui folder`

**Step 2.** Open a terminal inside VS Code:
`Terminal → New Terminal`

**Step 3.** Initialise a Git repository (required for Copilot to work properly):

```bash
git init
```

**Step 4.** Create the `.github` folder structure Copilot uses:

```bash
mkdir -p .github/instructions
mkdir -p .github/prompts
```

**Step 5.** Copy the `copilot-instructions.md` file (provided separately) into `.github/`:

```
your-project/
└── .github/
    ├── copilot-instructions.md   ← paste this file here
    ├── instructions/
    └── prompts/
```

**Step 6.** Save the file. Copilot picks it up immediately — no restart needed.

**Step 7.** Verify Copilot is reading it: open Copilot Chat, ask any question, then look at the **References** section at the bottom of the response. You should see `copilot-instructions.md` listed there.

---

## Part 4 — Install Useful Instructions from Awesome Copilot

The Awesome Copilot repo has a Python instructions file worth adding. It gives Copilot Flask/FastAPI best practices automatically.

**Step 1.** Go to: [https://github.com/github/awesome-copilot](https://github.com/github/awesome-copilot)

**Step 2.** Navigate to `instructions/` folder and look for `python.instructions.md` or `python-flask.instructions.md`

**Step 3.** Click the **"Install in VS Code"** button next to it — this automatically drops the file into your project's `.github/instructions/` folder

**Step 4.** Also look for and install `linux.instructions.md` or `debian.instructions.md` if available — useful for the installer bash scripts

**Step 5.** Also look for `security.instructions.md` — relevant given the password/encryption requirements in this project

> **Note:** Instructions in `.github/instructions/` apply to specific file types (e.g. only `*.py` files). Instructions in `.github/copilot-instructions.md` apply to everything. Both work together.

---

## Part 5 — Enable Agent Mode (the most powerful feature)

Agent mode lets Copilot write multiple files, run terminal commands, and build entire features autonomously.

**Step 1.** Open Copilot Chat (`Ctrl+Alt+I`)

**Step 2.** At the top of the chat panel, click the mode dropdown — switch from **"Ask"** to **"Agent"**

**Step 3.** You're now in agent mode. Copilot can now create files, edit multiple files at once, run commands, and self-correct errors

---

## Part 6 — How to Use Copilot Effectively for This Project

### The Golden Rule

**Never ask Copilot to build the whole project at once.** Break it into small, focused sessions — one component at a time. The `copilot-instructions.md` file keeps everything consistent between sessions.

### Recommended Build Order

Work through the project in this sequence, one session per item:

1. Project structure and `requirements.txt` / file scaffold
2. Installer Script 1 — host script (whiptail dialogs, VM creation)
3. Installer Script 2 — VM setup script (driver install, phev2mqtt build)
4. Web UI authentication (first-run gate, bcrypt, session management)
5. Settings page — WiFi section (backend + frontend)
6. Settings page — MQTT section
7. Settings page — phev2mqtt service controls
8. Settings page — SSH toggle, password change, resource monitoring
9. Log management (journald config, logrotate, log level controls)
10. Update manager (OS updates + phev2mqtt updates)
11. Terminal & Tools page (xterm.js, pre-built commands)
12. Vehicle emulator
13. Log download with obfuscation
14. README file

### How to Start Each Session

Open a **new** Copilot Chat in Agent mode and start with this pattern:

```
I'm building the phev2mqtt web UI project. Today I'm working on [component name].
The full spec is in copilot-instructions.md.

Please start by:
1. Showing me what files you plan to create or modify
2. Waiting for my confirmation before writing any code
```

This prevents Copilot from diving straight into code before you've agreed on the approach.

### Useful Commands During a Session

| What you want                | What to type                                                                  |
| ---------------------------- | ----------------------------------------------------------------------------- |
| Review what it's about to do | _"Show me your plan before writing code"_                                     |
| Catch it drifting from spec  | _"Check copilot-instructions.md — does this match the spec?"_                 |
| Fix something it got wrong   | _"This doesn't match the spec — [explain]. Please redo."_                     |
| Ask it to add tests          | _"Write tests for what you just built"_                                       |
| Check security               | _"Review this for security issues against the spec requirements"_             |
| Generate the README          | _"Generate the README.md following the structure in copilot-instructions.md"_ |

### When Copilot Goes Off-Track

This will happen. Common issues and fixes:

- **It uses the wrong stack** (e.g. Django instead of Flask) → Say _"The spec requires Flask/FastAPI, not Django. Please redo."_
- **It skips security requirements** (e.g. no bcrypt) → Say _"Check the authentication section of copilot-instructions.md — passwords must be bcrypt encrypted."_
- **It creates too many files at once** → Say _"Stop. Let's do one file at a time. Start with [specific file]."_
- **It forgets the binary path** → Say _"All phev2mqtt commands must use `/usr/local/bin/phev2mqtt` — fix this."_

---

## Part 7 — Verifying Copilot Is Using Your Instructions

After any Copilot response, scroll to the bottom of the chat panel and look for a **References** section. If `copilot-instructions.md` appears there, Copilot used your instructions. If it doesn't appear, check:

- The file is saved at exactly `.github/copilot-instructions.md`
- VS Code setting `GitHub Copilot: Use Instruction Files` is enabled (`Ctrl+,` → search "instruction file")
- You're in Agent or Edit mode, not Ask mode (instructions apply to all modes but are most effective in Agent)

---

## Part 8 — Recommended VS Code Extensions

Install these alongside Copilot to make development smoother:

| Extension                    | Why                                                                 |
| ---------------------------- | ------------------------------------------------------------------- |
| **Python** (Microsoft)       | Essential for Flask/FastAPI development                             |
| **Pylance**                  | Better Python IntelliSense                                          |
| **Shell Script** (timonwong) | Syntax highlighting for bash installer scripts                      |
| **Remote - SSH**             | Connect directly to your Proxmox VM for testing                     |
| **GitLens**                  | Better Git history — useful for tracking upstream phev2mqtt changes |
| **REST Client**              | Test the web UI API endpoints without a browser                     |
