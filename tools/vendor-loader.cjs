// A small CommonJS resolver for the locked, ordinary-file dependency tree.
// Package sources are unmodified; dependencies resolve according to vendor/npm/lock.json.
const Module = require('node:module');
const path = require('node:path');
const vendor = path.resolve(__dirname, '../vendor/npm');
const lock = require('../vendor/npm/lock.json');
const original = Module._resolveFilename;

Module._resolveFilename = function (request, parent, ...rest) {
  if (!Module.isBuiltin(request) && !request.startsWith('.') && !path.isAbsolute(request)) {
    const parts = request.split('/');
    const name = request.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
    const suffix = request.slice(name.length);
    const relative = parent?.filename ? path.relative(vendor, parent.filename) : '';
    const parentId = !relative.startsWith('..') ? relative.split(path.sep)[0] : '';
    const parentPackage = lock.packages[parentId];
    const id = parentPackage?.name === name ? parentId : parentPackage?.dependencies[name]
      ?? (name === 'hardhat' ? lock.hardhat : undefined);
    if (id) return original.call(this, path.join(vendor, id, suffix), parent, ...rest);
  }
  return original.call(this, request, parent, ...rest);
};
