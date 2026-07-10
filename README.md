# TEB Hub

TEB Hub is a unified Roblox utility interface that combines Bloom automation, fruit mailing, optimization tools, counters, auto-rejoin, and cloud-based settings into one responsive menu.

The hub uses a single centered window with sidebar navigation instead of opening a separate UI for every module.

## Features

### Unified Interface

- One large centered window
- Responsive scaling for smaller screens and mobile devices
- Sidebar navigation
- Draggable main window
- Minimize and close controls
- Dashboard for enabling and opening modules
- Standardized layout across all included tools

### Bloom Automation

- Supports Moon Bloom and Hypno Bloom
- Automatic sprinkler placement
- Automatic watering-can use
- KG threshold filtering
- Above and Below KG modes
- Ratio-based auto-start and auto-stop
- Plant-count requirement
- Harvest-completion tracking
- Good Ripe, Good Growing, Bad Ripe, and Bad Growing counters
- Selectable sprinklers
- Selectable watering cans
- Cloud-saved Bloom settings

### Fruit Multi-Mailer

- Multi-user mailing
- Value-based target mode
- Fruit-based target mode
- Fruit-name filtering
- Fruit-count targets
- Base-value calculation
- Current-value display
- Per-recipient targets
- Maximum of 20 fruits per mail
- Cooldown handling
- Live refill support
- Preview mode
- Progress display
- Trade history
- Expandable logs
- Avatar cards
- Cloud-saved mailer settings

### Optimization and Counter

- Removes or disables unnecessary visual effects
- Optimizes BaseParts
- Removes selected fruit and plant visuals
- Reduces texture, mesh, lighting, and effect load
- Tracks plant count
- Tracks fruit count
- Handles future Workspace descendants
- Runs inside the unified hub

> Turning optimization off only stops future processing. Objects already removed or modified cannot automatically be restored.

### Auto Rejoin

- Detects Roblox error messages
- Configurable delay in seconds
- Countdown status
- Rejoins the current place
- Can be enabled or disabled from the hub
- Delay is saved in cloud config

## Pages

The sidebar contains:

- Dashboard
- Bloom Automation
- Fruit Mailer
- Optimizer
- Auto Rejoin
- Cloud & Defaults

## Installation

Host the Lua script on a raw-file service such as GitHub.

Example raw URL:

```text
https://raw.githubusercontent.com/Countz872/Scripts/refs/heads/main/TebHub_Loader.lua
```

Example loader:

```lua
loadstring(game:HttpGet(
   "https://raw.githubusercontent.com/Countz872/Scripts/refs/heads/main/TebHub_Loader.lua"
))()
```

The URL must return plain Lua source code.

## Cloudflare Configuration

TEB Hub uses a Cloudflare Worker and Workers KV to save settings outside the device.

Current Worker endpoint:

```text
https://scripts-gag2.tucodanj.workers.dev
```

The Worker must support:

```text
POST /load
POST /save
POST /set-default
```

## KV Binding

The Cloudflare Worker must have a Workers KV binding named:

```text
CONFIGS
```

The Worker code accesses it as:

```javascript
env.CONFIGS
```

## Wrangler Configuration

Repository structure:

```text
project-root/
├── package.json
├── wrangler.jsonc
└── src/
    └── index.js
```

Example `wrangler.jsonc`:

```jsonc
{
  "$schema": "node_modules/wrangler/config-schema.json",
  "name": "bloom-config-api",
  "main": "src/index.js",
  "compatibility_date": "2026-07-10",
  "kv_namespaces": [
    {
      "binding": "CONFIGS",
      "id": "YOUR_KV_NAMESPACE_ID"
    }
  ]
}
```

Example `package.json`:

```json
{
  "name": "bloom-config-api",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "deploy": "wrangler deploy",
    "dev": "wrangler dev"
  },
  "devDependencies": {
    "wrangler": "^4.110.0"
  }
}
```

Deploy command:

```bash
npx wrangler deploy
```

## Cloud Config Scopes

Settings are separated into scopes:

```text
hub
bloom
mailer
```

### Hub scope

Stores:

- Bloom enabled state
- Mailer enabled state
- Optimizer enabled state
- Auto-rejoin enabled state
- Auto-rejoin delay
- Hub minimized state
- Hub position

### Bloom scope

Stores:

- Master enabled
- Automation enabled
- KG threshold
- KG filter enabled
- Above or Below mode
- Ratio automation enabled
- Start ratio
- Stop ratio
- Selected sprinklers
- Selected watering cans
- Bloom UI state

### Mailer scope

Stores:

- Target mode
- Recipient text
- Value target
- Fruit target name
- Fruit target count
- Packet sequence

## UserId-Based Settings

TEB Hub automatically uses the local player's Roblox UserId to identify the cloud configuration.

Example key format:

```text
TEBHubUser-123456789
```

No HWID, `readfile`, or `writefile` is required.

Because Roblox UserIds are public, this is convenient but not secure authentication.

## Default Config Priority

The Worker loads settings in this order:

```text
1. UserId-specific configuration
2. Global default configuration
3. Script defaults
```

A player's saved configuration always takes priority over the global default.

## Setting the Global Default

Open the Cloud & Defaults page and press:

```text
Set Current Settings as Default
```

This stores the current hub, Bloom, and mailer settings as the global fallback.

For complete module defaults:

1. Enable Bloom Automation.
2. Configure Bloom settings.
3. Enable Fruit Mailer.
4. Configure mailer settings.
5. Configure hub and auto-rejoin settings.
6. Open Cloud & Defaults.
7. Press **Set Current Settings as Default**.

Players with existing UserId saves will continue using their personal settings.

## Fruit Mailer Modes

### Value Mode

Enter a target value such as:

```text
1B
500M
250000000
```

The mailer selects fruits to meet or slightly exceed the target.

### Fruit Mode

Enter:

```text
Fruit name: Moon Bloom
Count: 100
```

The mailer sends matching fruits by quantity while still showing:

- Base value
- Current value
- Batch value
- Total sent value
- Progress
- Trade history

Fruit-name matching is normalized, so variations such as these are treated similarly:

```text
Moon Bloom
moon bloom
MoonBloom
```

## Auto-Rejoin Delay

The delay accepts values from:

```text
0 to 3600 seconds
```

Example:

```text
150
```

The setting is saved to the UserId cloud config.

## Responsive UI

The default hub size is:

```text
920 × 620
```

It automatically scales down to fit smaller displays.

The hub remains centered and keeps one consistent interface across modules.

## Important Notes

- The optimizer permanently changes or removes some client-visible objects.
- The script depends on the game's current instance structure and packet format.
- Game updates may require packet IDs, paths, attributes, or UI paths to be updated.
- The Worker endpoint must begin with `https://`.
- Do not add `/load` or `/save` to the configured base endpoint.
- The KV binding must be named exactly `CONFIGS`.
- A public client script cannot securely protect an administrator secret.
- The current default-config endpoint should only be used in a trusted or private setup.

## Troubleshooting

### Invalid URL for HTTP request

Use:

```lua
Endpoint = "https://scripts-gag2.tucodanj.workers.dev"
```

Do not use:

```lua
Endpoint = "scripts-gag2.tucodanj.workers.dev"
```

### Worker returns `Use POST`

That is expected when opening the Worker URL in a browser.

It confirms the Worker is online, because the browser sends a GET request while the API expects POST.

### Wrangler treats the project as a static site

Make sure `wrangler.jsonc` contains:

```jsonc
"main": "src/index.js"
```

### `Expected ";" but found ":"`

The `wrangler.jsonc` contents were likely pasted into `src/index.js`.

Keep:

```text
wrangler.jsonc
```

and:

```text
src/index.js
```

as separate files.

### Cloud config does not save

Check:

- Worker deployment succeeded
- Endpoint starts with `https://`
- KV binding is named `CONFIGS`
- KV namespace ID is correct
- Worker supports the required routes
- The execution environment supports HTTP request functions

## Disclaimer

Use TEB Hub only where you are authorized to run and modify the included systems. You are responsible for complying with Roblox rules, the game owner's rules, and any applicable platform policies.
