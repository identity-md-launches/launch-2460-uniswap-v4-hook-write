#!/usr/bin/env node
const path = require('node:path');
const root = path.resolve(__dirname, '..');
// Keep all runtime state in ignored project directories, with telemetry disabled.
process.env.XDG_CONFIG_HOME = path.join(root, 'cache-hardhat/global/config');
process.env.XDG_CACHE_HOME = path.join(root, 'cache-hardhat/global/cache');
process.env.XDG_DATA_HOME = path.join(root, 'cache-hardhat/global/data');
process.env.HARDHAT_DISABLE_TELEMETRY_PROMPT = 'true';
require('./vendor-loader.cjs');
const globalDir = require('hardhat/internal/util/global-dir');
globalDir.hasConsentedTelemetry = () => false;
// Avoid legacy home-directory analytics IDs and optional online release banners as well.
const { Analytics } = require('hardhat/internal/cli/analytics');
Analytics.getInstance = async () => ({ sendTaskHit: async () => [() => {}, Promise.resolve()] });
const { BannerManager } = require('hardhat/internal/cli/banner-manager');
BannerManager.getInstance = async () => ({ showBanner: async () => {} });
// CLI import below executes the genuine pinned Hardhat entry point.
require('hardhat/internal/cli/cli');
