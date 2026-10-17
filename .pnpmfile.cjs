/* eslint-disable no-console */

const fs = require("fs");
const { execSync, execFileSync } = require("child_process");

const discourseRoot = __dirname;

if (fs.existsSync(`${discourseRoot}/node_modules/.yarn-integrity`)) {
  console.log(
    "Detected yarn-managed node_modules. Performing one-time cleanup..."
  );

  // Delete entire contents of all node_modules directories
  // But keep the directories themselves, in case they are volume mounts (e.g. in devcontainer)
  execSync(
    `find ${discourseRoot}/node_modules ${discourseRoot}/app/assets/javascripts/*/node_modules -mindepth 1 -maxdepth 1 -exec rm -rf {} +`
  );

  console.log("cleanup done");
}

// discourse/base images have shipped a stale frontend/discourse-types/node_modules/@types
// snapshot baked in at image-build time (e.g. @types/@glint__ember-tsc, @types/@glimmer__component).
// A valid @types/<name> entry never itself starts with "@", so any that do are leftovers from an
// older, incompatible layout. node_modules is gitignored, so a bootstrap's git checkout never
// clears them, and pnpm then refuses to place real dependencies over them with
// ERR_PNPM_INVALID_DEPENDENCY_NAME. Clear them before pnpm runs.
const staleTypesDir = `${discourseRoot}/frontend/discourse-types/node_modules/@types`;
if (fs.existsSync(staleTypesDir)) {
  for (const entry of fs.readdirSync(staleTypesDir)) {
    if (entry.startsWith("@")) {
      console.log(
        `[.pnpmfile.cjs] Removing stale invalid @types entry: ${entry}`
      );
      fs.rmSync(`${staleTypesDir}/${entry}`, { recursive: true, force: true });
    }
  }
}

const oldFrontendPath = `app/assets/javascripts`;
if (fs.existsSync(`${discourseRoot}/${oldFrontendPath}`)) {
  console.log(
    `[.pnpmfile.cjs] Detected old ${oldFrontendPath} directory. Cleaning up gitignored files...`
  );
  execSync(`git clean -f -X ${oldFrontendPath}`, { cwd: discourseRoot });

  if (fs.existsSync(`${discourseRoot}/${oldFrontendPath}`)) {
    const anyFiles = !!execSync(
      `find "${oldFrontendPath}" -mindepth 1 -type f -print -quit`,
      { encoding: "utf8", cwd: discourseRoot }
    ).trim();

    if (!anyFiles) {
      fs.rmSync(oldFrontendPath, {
        recursive: true,
      });
    }
  }
}

const pluginBase = `${discourseRoot}/plugins/`;
const cwd = process.cwd();
const pluginName =
  cwd.startsWith(pluginBase) && cwd.replace(pluginBase, "").split("/", 2)[0];

if (
  pluginName &&
  fs.existsSync(`${discourseRoot}/plugins/${pluginName}/pnpm-lock.yaml`) &&
  !process.argv.includes("--ignore-workspace")
) {
  console.log(
    "> pnpm was run inside a plugin directory. Re-executing with --ignore-workspace..."
  );

  const indexOfPnpm = process.argv.findIndex(
    (a) => a.includes("/pnpm") || a.endsWith("pnpm")
  );
  const newArgs = [...process.argv];
  newArgs.splice(indexOfPnpm + 1, 0, "--ignore-workspace");

  try {
    execFileSync(newArgs[0], newArgs.slice(1), {
      stdio: "inherit",
    });
  } catch (e) {
    if (e.status) {
      process.exit(e.status);
    }
    throw e;
  }

  process.exit(0);
}
