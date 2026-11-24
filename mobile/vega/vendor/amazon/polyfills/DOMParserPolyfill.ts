/*
 * Copyright 2025 Amazon.com, Inc. or its affiliates. All rights reserved.
 *
 * AMAZON PROPRIETARY/CONFIDENTIAL
 *
 * You may not use this file except in compliance with the terms and
 * conditions set forth in the accompanying LICENSE.TXT file.
 *
 * THESE MATERIALS ARE PROVIDED ON AN "AS IS" BASIS. AMAZON SPECIFICALLY
 * DISCLAIMS, WITH RESPECT TO THESE MATERIALS, ALL WARRANTIES, EXPRESS,
 * IMPLIED, OR STATUTORY, INCLUDING THE IMPLIED WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, AND NON-INFRINGEMENT.
 */

// @ts-nocheck

// CustomDOMParser tries native xml parser provided by native-player-utils
// (global.nativeParseFromString) and lazy-loads @xmldom/xmldom only on fallback.
class CustomDOMParser {
  private fallbackParser: any;

  constructor() {
    if (typeof __DEV__ !== 'undefined' && __DEV__) console.log(`CustomDOMParser created`);
  }

  parseFromString(str: string, mimeType: string) {
    if (typeof __DEV__ !== 'undefined' && __DEV__) {
      console.log(`CustomDOMParser::parseFromString`);
      console.log(`shaka: global.nativeParseFromString = ${!!global.nativeParseFromString}`);
    }
    if (global.nativeParseFromString) {
      if (typeof __DEV__ !== 'undefined' && __DEV__) {
        console.log(`nativeParseFromString available`);
        console.log(`calling XmlUtils.nativeParseFromString, mime:`, mimeType);
      }
      return global.nativeParseFromString(str);
    } else {
      if (typeof __DEV__ !== 'undefined' && __DEV__) {
        console.log(`nativeParseFromString not available`);
        console.log(`calling DomParser's parseFromString`);
      }
      if (!this.fallbackParser) {
        const {DOMParser} = require('@xmldom/xmldom');
        this.fallbackParser = new DOMParser();
      }
      return this.fallbackParser.parseFromString(str, mimeType);
    }
  }
}

class DOMParserPolyfill {
  static install() {
    if (typeof __DEV__ !== 'undefined' && __DEV__) console.log('Installing dom parser polyfills');
    if (typeof window !== 'undefined') {
      try {
        global.window.DOMParser = CustomDOMParser;
        global.DOMParser = CustomDOMParser;
        if (typeof __DEV__ !== 'undefined' && __DEV__) console.log('Installed dom parser polyfills');
      } catch (e) {
        console.warn('Failed to install DOMParser polyfill:', e);
      }
    }
  }
}

export default DOMParserPolyfill;
