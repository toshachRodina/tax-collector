const fs = require('fs');
const path = 'c:/Users/tosha/repos/tax-collector/prod/workflows/WIP_EXTRACT_GMAIL.json';
const wf = JSON.parse(fs.readFileSync(path, 'utf8'));

const fam = wf.nodes.find(n => n.name === 'Find Attachment Meta');

// Strip apostrophes/single-quotes from safeName — they break shell single-quoting
fam.parameters.jsCode = fam.parameters.jsCode.replace(
  `safeName = filename.replace(/[\\\\/:"*?<>|]/g, '_');`,
  `safeName = filename.replace(/[\\\\/:"*?<>|']/g, '_');`
);

console.log('safeName line after fix:', fam.parameters.jsCode.match(/safeName = filename.*/)[0]);

const out = JSON.stringify(wf, null, 2);
JSON.parse(out);
fs.writeFileSync(path, out, 'utf8');
console.log('Written.');
