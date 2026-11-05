# Working on HODDR Launchpad

Use CodeHands v8 Pro in the existing workspace. Keep each helper in its own session.

- Keep all launchpad source, output, caches and local chain state inside this directory.
- Treat parent/shared dependency references and the existing crypto-social application as read-only.
- Never commit environment files, signing material, private proof data, local ledgers or local chain state.
- Frontend configuration must not load or expose the test-wallet environment.
- Use actual protocol contracts for chain behavior. Label synthetic local identity fixtures explicitly.
- Root coordinates commits and pushes after reviewing each milestone; helpers do not stage or commit shared work.
- Preserve upstream license notices. New project code is UNLICENSED until the owner chooses a project license.
