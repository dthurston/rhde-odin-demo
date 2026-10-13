# ODIN golden profile

`profile.tgz` here is the standard ODIN setup pushed to every C2 node:
the project, the offline map service, the live ISR source, the map view, and drawn units.

- Create or refresh it: `sudo ./tools/odin-profile.sh capture edge-a`. Run it on the control node, from a node you've configured by hand.
- Push it: `sudo ./tools/odin-profile.sh apply all`, or `apply edge-b`.

To keep the profile in git, copy it from `/opt/edge-demo/odin/` into your clone's `odin/` folder and commit it. It contains only demo map data, no credentials.
