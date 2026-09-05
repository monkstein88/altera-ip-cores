#!/usr/bin/env node
/*
 * render.js - turn the WaveDrom JSON that mkwaves.py emits into SVG.
 *
 *   node render.js <in.json> <out.svg>
 *
 * WaveDrom is a library, not a command, and the published CLI wrapper wants a
 * global install. This is the whole of what the wrapper does: load the JSON,
 * render it against the default skin, serialise the result.
 *
 * Install the dependency next to this file:
 *
 *   cd doc/tools/waveforms && npm install wavedrom onml
 *
 * node_modules/ is not tracked - see .gitignore. The SVGs it produces are,
 * because the documents embed them and not everyone building this repository
 * has Node.
 */
'use strict';

const fs = require('fs');
const path = require('path');

function load(name) {
    // Look next to this script first, then wherever Node would normally look,
    // so a global install works too.
    try {
        return require(path.join(__dirname, 'node_modules', name));
    } catch (e) {
        return require(name);
    }
}

let wavedrom, onml;
try {
    wavedrom = load('wavedrom');
    onml = load('onml');
} catch (e) {
    process.stderr.write(
        'error: wavedrom not installed.\n' +
        '       cd doc/tools/waveforms && npm install wavedrom onml\n');
    process.exit(2);
}

const [, , inPath, outPath] = process.argv;
if (!inPath || !outPath) {
    process.stderr.write('usage: node render.js <in.json> <out.svg>\n');
    process.exit(1);
}

const src = JSON.parse(fs.readFileSync(inPath, 'utf8'));
const rendered = wavedrom.renderAny(0, src, wavedrom.waveSkin);
fs.writeFileSync(outPath, onml.stringify(rendered) + '\n');
