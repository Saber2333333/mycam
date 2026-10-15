# MyCam iPhone app, built in the cloud (no Mac needed)

1. Make a free account at github.com, then New repository, name it mycam, set it to Public, Create.
2. On the new repo page click "uploading an existing file". Drag in everything from this folder
   (MyCam folder, project.yml, README.md). Click Commit changes.
3. The hidden .github folder may not upload by drag. Click Add file > Create new file, type the name
   .github/workflows/build.yml  (typing the slashes makes the folders), paste the contents of
   build.yml from this zip, and click Commit changes.
4. Open the Actions tab. A run called "Build iPhone app" starts (about 5 minutes). If it fails, click it,
   copy the red error text, and send it to Claude.
5. When it shows a green check, open the run and download the artifact "MyCam-ipa". Unzip it to get MyCam.ipa.
6. Install Sideloadly from sideloadly.io on Windows (it needs iTunes, which you need anyway for USB).
   Plug in the iPhone, drag MyCam.ipa into Sideloadly, enter your Apple ID, click Start.
7. On the iPhone: Settings > General > VPN & Device Management > your Apple ID > Trust.
   Free Apple ID installs expire after 7 days. Repeat step 6 to renew.
