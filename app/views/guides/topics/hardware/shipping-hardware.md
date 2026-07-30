# Shipping your Hardware Projects

Now that you have the design files, it's time to actually ship your hardware project and get it ready to submit!

_want to learn more about shipping? read more at the [codex](https://codex.hackclub.com/shipping)_

## 1. Make sure you have all of your project files!

First off - check that all your project's files are actually in the repository! This includes a full CAD assembly in .STEP format, your PCB source files, and your firmware! This ensures that other people will actually be able to replicate your project!

It should look something like this:

![image](https://cdn.hackclub.com/019faa27-0dd7-78d7-ab11-79af1ad1b14e/paste-1785266113485.png)

_It's really hard to tell the difference between all the different files!_

## 2. Organize the different files!

Next, you should organize all your different files!

I recommend making 3 folders - one called "CAD", one called "PCB", and one called "firmware"

Drag and drop your files into their respective folders. Here's an example of what they should look like!

![image](https://cdn.hackclub.com/019faa2b-5bd4-7d82-a47d-3a43fd08760c/paste-1785266395604.png)
_same files, but organized this time around!_

## 3. Make a Bill Of Materials!

The next step is to make a bill of materials (BOM)!

A bill of materials is a list of all the parts & materials needed to make your project! You should include any components, modules, and any other parts you may need.

![image](https://cdn.hackclub.com/019faa3a-e3a5-7762-83fe-26dee71aaaea/paste-1785267413776.png)
You should store this in a **csv** (comma-separated value) format. It's plain text and works across almost every platform.

You can make your own, or use this template [here](https://docs.google.com/spreadsheets/d/1maI6o3gMH7iFf2YkcOIJNg3B32JRLoNRscTOKz6hCpg/edit?usp=sharing).

It may be tempting to skip this step, but it'll make it much easier to order your parts later!

## 4. Write a README.md about your project!

A README.md file is what ties your project together! It should include a short description of your project (what it does, how it works, why you made it), and also screenshots of your project!

Here's an example of what that looks like!

![image](https://cdn.hackclub.com/019faa3b-b681-71a1-845d-163630397f07/paste-1785267467646.png)

Make sure to include a screenshot of your PCB(s)/wiring diagram if applicable - it makes reviewing way easier for us and cuts down on time!

One snippet you can add to your project is this. It adds a PCB button to your README that opens your repository's PCB!

```
[![View PCB on KiCanvas](https://hack.club/pcb-badge)](https://kicanvas.org/?repo=https://github.com/<OWNER>/<REPOSITORY>/tree/main/pcb)
```

[![View PCB on KiCanvas](https://hack.club/pcb-badge)](https://kicanvas.org/?repo=https://github.com/hackclub/orpheus-pico)

## 5. Submit!

Once you're done with your project, you're ready to submit!

If you just finished a _design_ and are looking for funding, submit it for funding from your project page

If you have a build, hang tight!
