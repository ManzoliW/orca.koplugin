# README screenshots

The screenshots in the main README come from a real Kindle running the plugin
with [`demo.lua`](demo.lua): made-up projects, sessions, pull requests and
conversations instead of your own, plus a reading history. Nothing private ends
up in the pictures, and they can be taken again whenever a screen changes.

1. Deploy the plugin, then append the demo to the deployed client (it replaces
   the client's last line, `return Client`):

   ```sh
   python tools/kindlectl.py deploy
   scp tools/screenshots/demo.lua root@$KINDLE_HOST:/tmp/demo.lua
   ssh root@$KINDLE_HOST 'cd /mnt/us/koreader/plugins/orca.koplugin &&
     sed -i "\$d" orcaclient/client.lua && cat /tmp/demo.lua >> orcaclient/client.lua'
   ```

2. For English pictures, set KOReader's language to English (Settings →
   Language), then `python tools/kindlectl.py restart`.
3. Open Orca and take each screen with `python tools/kindlectl.py shot
   docs/screenshots/<name>.png`. `touch /tmp/orca-demo-notify` on the Kindle
   pops a notification over the book. The sleep picture is the PNG the plugin
   draws: copy `/mnt/us/koreader/cache/orca-sleep/orca.png`.
4. Redraw the cover from three of them:
   `python tools/screenshots/cover.py [left.png middle.png right.png]`
   (defaults: a session, Home and the heatmaps).
5. Deploy again to remove the demo, and set the language back.

The GitHub contribution calendar and the book on the Kindle are real.
