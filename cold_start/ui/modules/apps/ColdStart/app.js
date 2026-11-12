// Cold Start - live cold start panel and settings.
// Vehicle data arrives on the "coldStart" vehicle stream; settings on the "ColdStartSettings" hook.
'use strict';

{
  const lua = function (expr) {
    if (!window.bngApi || !window.bngApi.engineLua) return;
    window.bngApi.engineLua(
      'if not coldStartManager then extensions.load("coldStartManager") end; if coldStartManager then coldStartManager.' + expr + ' end'
    );
  };
  const luaValue = function (v) {
    if (v === true || v === false) return String(v);
    if (v === null || v === undefined || v === '') return 'nil';
    if (typeof v === 'number') return isFinite(v) ? String(v) : 'nil';
    return '"' + String(v).replace(/[^A-Za-z0-9_\-.]/g, '') + '"';
  };

  const store = {
    get: function (k, d) { try { const v = localStorage.getItem('coldStart.' + k); return v === null ? d : v; } catch (e) { return d; } },
    set: function (k, v) { try { localStorage.setItem('coldStart.' + k, v); } catch (e) {} }
  };

  const icon = function (body) {
    return '<svg class="cst-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' + body + '</svg>';
  };
  const ICONS = {
    flake: icon('<path d="M12 2v20M3.3 7l17.4 10M20.7 7L3.3 17M12 6l-2.5-2.5M12 6l2.5-2.5M12 18l-2.5 2.5M12 18l2.5 2.5"/>'),
    outside: icon('<path d="M10 14.5V5a2 2 0 0 1 4 0v9.5a4 4 0 1 1-4 0z"/><path d="M12 10v6"/>'),
    engine: icon('<path d="M4 10h3l2-2h6l2 2h2v3h1v-2h1v7h-1v-2h-1v3h-4l-2 2H9l-2-2H4z"/><path d="M10 5h4M12 5v3"/>'),
    battery: icon('<rect x="2.5" y="7" width="19" height="12" rx="2"/><path d="M6 7V5M18 7V5M6 13h3M15 13h3M16.5 11.5v3"/>'),
    key: icon('<circle cx="7.5" cy="14.5" r="3.5"/><path d="M10.3 12.2L20 4M16.5 7l2.5 2.5M14 9l2 2"/>'),
    gear: icon('<circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M18.7 5.3l-2.1 2.1M7.4 16.6l-2.1 2.1"/>')
  };

  const template =
    '<div class="cst bngApp">' +
      '<link type="text/css" rel="stylesheet" href="/ui/modules/apps/ColdStart/app.css">' +
      '<div class="cst-header">' +
        '<span class="cst-logo">' + ICONS.flake + '</span>' +
        '<span class="cst-title">Cold Start</span>' +
        '<span class="cst-chip" title="Realism preset">{{ presetLabel() }}</span>' +
        '<button class="cst-icon" ng-class="{active: view === \'settings\'}" ng-click="setView(view === \'settings\' ? \'main\' : \'settings\')" title="Settings">' + ICONS.gear + '</button>' +
      '</div>' +

      // Main panel ----------------------------------------------------------------------------------
      '<div class="cst-body" ng-if="view === \'main\'">' +
        '<div class="cst-grid">' +
          '<div class="cst-tile">' +
            '<div class="cst-label">' + ICONS.outside + '<span>Outside</span>' +
              '<span class="cst-step">' +
                '<button ng-click="nudge(-1, $event)" title="Colder (Shift: 5 degrees)">&minus;</button>' +
                '<button ng-click="nudge(1, $event)" title="Warmer (Shift: 5 degrees)">+</button>' +
              '</span>' +
            '</div>' +
            '<div class="cst-value" ng-style="{color: tempColor(data.outside)}">{{ fmtTemp(data.outside) }}</div>' +
            '<div class="cst-sub">{{ outsideSource() }}</div>' +
          '</div>' +

          '<div class="cst-tile">' +
            '<div class="cst-label">' + ICONS.engine + '<span>Engine</span><span class="cst-tag" ng-if="data.diesel">diesel</span></div>' +
            '<div class="cst-value" ng-style="{color: tempColor(data.engineTemp)}">{{ data.hasEngine ? fmtTemp(data.engineTemp) : "n/a" }}</div>' +
            '<div class="cst-bar"><div ng-style="{width: warmth(data.engineTemp) + \'%\', background: tempColor(data.engineTemp)}"></div></div>' +
          '</div>' +

          '<div class="cst-tile">' +
            '<div class="cst-label">' + ICONS.battery + '<span>Battery</span><span class="cst-tag cst-num">{{ fmtVolts(data.volts) }}</span></div>' +
            '<div class="cst-value" ng-style="{color: batteryColor(data.battery)}">{{ data.hasEngine ? fmtPercent(data.battery) : "n/a" }}</div>' +
            '<div class="cst-bar"><div ng-style="{width: ((data.battery || 0) * 100) + \'%\', background: batteryColor(data.battery)}"></div></div>' +
          '</div>' +

          '<div class="cst-tile">' +
            '<div class="cst-label">' + ICONS.key + '<span>Start</span><span class="cst-tag cst-num" ng-if="data.attempts">try {{ data.attempts }}</span></div>' +
            '<div class="cst-value cst-word" ng-style="{color: startColor()}">{{ startLabel() }}</div>' +
            '<div class="cst-bar" ng-if="showCrankBar()"><div ng-style="{width: crankBar() + \'%\', background: startColor()}"></div></div>' +
            '<div class="cst-sub" ng-if="!showCrankBar()">{{ startSub() }}</div>' +
          '</div>' +
        '</div>' +

        '<div class="cst-meters" ng-if="data.hasEngine && data.active">' +
          '<div class="cst-meter" ng-if="data.diesel" title="Glow plugs"><span>Glow</span><div class="cst-bar"><div ng-style="{width: (data.glow * 100) + \'%\', background: data.glow >= 0.98 ? \'#4cc38a\' : \'#f5b544\'}"></div></div></div>' +
          '<div class="cst-meter" ng-if="!data.diesel" title="Unburnt fuel on the plugs"><span>Flood</span><div class="cst-bar"><div ng-style="{width: (data.flood * 100) + \'%\', background: data.flood > 0.45 ? \'#ef5350\' : \'#8892a6\'}"></div></div></div>' +
          '<div class="cst-meter" title="Starter motor temperature"><span>Starter</span><div class="cst-bar"><div ng-style="{width: (data.starterHeat * 100) + \'%\', background: data.starterHeat > 0.75 ? \'#ef5350\' : \'#8892a6\'}"></div></div></div>' +
        '</div>' +

        '<div class="cst-hint" ng-class="\'cst-\' + hintTone()">{{ hintText() }}</div>' +
      '</div>' +

      // Settings ------------------------------------------------------------------------------------
      '<div class="cst-body cst-dim" ng-if="view === \'settings\' && !loaded">Loading settings&hellip;</div>' +
      // Rendered only once the settings have arrived: a range input without a value snaps to its
      // midpoint and would write that back as if the user had moved it.
      '<div class="cst-body cst-settings" ng-if="view === \'settings\' && loaded">' +
        '<div class="cst-section">Outside temperature <span class="cst-dim">now {{ fmtTemp(data.outside) }}</span></div>' +
        '<div class="cst-row">' +
          '<button ng-class="{active: !hasOverride()}" ng-click="set(\'outsideOverride\', null)">From level<span ng-if="settings.levelTemp !== undefined && settings.levelTemp !== null"> ({{ fmtTemp(settings.levelTemp) }})</span></button>' +
          '<button ng-repeat="t in tempPresets" ng-class="{active: settings.outsideOverride === t}" ng-click="set(\'outsideOverride\', t)">{{ fmtTemp(t) }}</button>' +
        '</div>' +
        '<div class="cst-slider">' +
          '<span>Custom</span>' +
          '<input type="range" min="-45" max="45" step="1" ng-model="slider.outside" ng-change="setLater(\'outsideOverride\', slider.outside)">' +
          '<b>{{ fmtTemp(slider.outside) }}</b>' +
        '</div>' +
        '<div class="cst-dim cst-small" ng-if="settings.overrideAvailable !== false">Sets the game&rsquo;s own air temperature, so the temperature gauge, engine warm-up and exhaust steam follow it. A parked car is cold-soaked to the new temperature.</div>' +
        '<div class="cst-banner" ng-if="settings.overrideAvailable === false">This game version does not let mods set the air temperature. The level&rsquo;s own temperature is used.</div>' +

        '<div class="cst-section">Realism</div>' +
        '<div class="cst-row">' +
          '<button ng-repeat="p in presets" ng-class="{active: settings.preset === p.id}" ng-click="set(\'preset\', p.id)" title="{{ p.hint }}">{{ p.label }}</button>' +
        '</div>' +
        '<label class="cst-toggle" ng-repeat="t in toggles track by t.key">' +
          '<input type="checkbox" ng-model="settings[t.key]" ng-change="set(t.key, settings[t.key])">' +
          '<span>{{ t.label }}</span><small>{{ t.hint }}</small>' +
        '</label>' +

        '<div class="cst-section">Battery</div>' +
        '<div class="cst-slider" title="How fast cranking, glow plugs and lights empty the battery">' +
          '<span>Drain</span>' +
          '<input type="range" min="0.25" max="3" step="0.25" ng-model="settings.batteryDrain" ng-change="setLater(\'batteryDrain\', settings.batteryDrain)">' +
          '<b>{{ fmtTimes(settings.batteryDrain) }}</b>' +
        '</div>' +
        '<div class="cst-slider" title="How fast the alternator charges it back. 1x is real time.">' +
          '<span>Charging</span>' +
          '<input type="range" min="1" max="20" step="1" ng-model="settings.chargeRate" ng-change="setLater(\'chargeRate\', settings.chargeRate)">' +
          '<b>{{ fmtTimes(settings.chargeRate) }}</b>' +
        '</div>' +

        '<div class="cst-section">Current vehicle</div>' +
        '<div class="cst-row">' +
          '<button ng-click="vehicleCall(\'coldSoak\')" title="Bring the whole engine down to outside temperature now">Cold soak now</button>' +
          '<button ng-class="{active: data.heater}" ng-click="vehicleCall(\'setHeater\', !data.heater)" title="Warms a parked engine. Unplugs itself when you drive off.">Block heater {{ data.heater ? "on" : "off" }}</button>' +
        '</div>' +
        '<div class="cst-row">' +
          '<button ng-click="vehicleCall(\'chargeBattery\')">Charge battery</button>' +
          '<button ng-repeat="b in batteryPresets" ng-click="vehicleCall(\'setBattery\', b)">{{ b }}%</button>' +
        '</div>' +
        '<div class="cst-dim cst-small" ng-if="data.hasEngine">Cold wear so far: +{{ (data.wear || 0).toFixed(1) }}% engine friction. False starts: {{ data.falseStarts || 0 }}.</div>' +

        '<div class="cst-section">Units</div>' +
        '<div class="cst-row">' +
          '<button ng-class="{active: units.temp === \'C\'}" ng-click="setUnit(\'C\')">&deg;C</button>' +
          '<button ng-class="{active: units.temp === \'F\'}" ng-click="setUnit(\'F\')">&deg;F</button>' +
          '<button class="cst-warn-btn" ng-click="resetSettings()">Reset all settings</button>' +
        '</div>' +
      '</div>' +
    '</div>';

  angular.module('beamng.apps')
    .directive('coldStart', [function () {
      return {
        template: template,
        replace: true,
        restrict: 'EA',
        link: function (scope) {
          const streamNames = ['coldStart'];
          StreamsManager.add(streamNames);

          scope.data = {hasEngine: true};
          scope.settings = {};
          scope.loaded = false;
          scope.slider = {outside: 0};
          scope.view = store.get('view', 'main');
          scope.units = {temp: store.get('tempUnit', 'C')};

          scope.presets = [
            {id: 'arcade', label: 'Arcade', hint: 'Cold matters less, false starts are rare'},
            {id: 'realistic', label: 'Realistic', hint: 'Tuned to how real engines and batteries behave'},
            {id: 'brutal', label: 'Brutal', hint: 'Worn engine, tired plugs: everything is harder'}
          ];
          scope.toggles = [
            {key: 'enabled', label: 'Cold start simulation', hint: 'master switch'},
            {key: 'wear', label: 'Cold engine wear', hint: 'revving on cold oil adds friction'},
            {key: 'soakOnReset', label: 'Cold engine after spawn / reset', hint: 'not pre-warmed'},
            {key: 'engineOffOnReset', label: 'Spawn with ignition off', hint: 'you have to start it yourself'},
            {key: 'rechargeOnReset', label: 'Full battery on vehicle reset', hint: 'reset repairs the car'},
            {key: 'aiVehicles', label: 'Parked and traffic cars too', hint: 'off = cars you drove'}
          ];
          scope.tempPresets = [-35, -24, -15, -5, 5, 20];
          scope.batteryPresets = [70, 40, 15];

          scope.setView = function (v) {
            scope.view = v;
            store.set('view', v);
            if (v === 'settings') lua('requestSettings()');
          };
          scope.setUnit = function (unit) {
            scope.units.temp = unit;
            store.set('tempUnit', unit);
          };

          scope.set = function (key, value) { lua('setSetting(' + luaValue(key) + ', ' + luaValue(value) + ')'); };
          // Sliders fire on every pixel; only send the last value.
          const sliderTimers = {};
          let confirmed = {};
          scope.setLater = function (key, value) {
            clearTimeout(sliderTimers[key]);
            value = Number(value);
            if (!isFinite(value) || value === confirmed[key]) return;
            sliderTimers[key] = setTimeout(function () { scope.set(key, value); }, 250);
          };
          scope.nudge = function (dir, event) { lua('nudgeOutside(' + (dir * (event && event.shiftKey ? 5 : 1)) + ')'); };
          scope.resetSettings = function () { lua('resetSettings()'); };
          scope.vehicleCall = function (fn, value) {
            lua('playerVehicleCall(' + luaValue(fn) + (value === undefined ? '' : ', ' + luaValue(value)) + ')');
          };
          scope.hasOverride = function () {
            return scope.settings.outsideOverride !== undefined && scope.settings.outsideOverride !== null;
          };

          // Formatting -------------------------------------------------------------------------
          scope.fmtTemp = function (c) {
            if (c === undefined || c === null || !isFinite(Number(c))) return '--';
            const v = scope.units.temp === 'F' ? Number(c) * 9 / 5 + 32 : Number(c);
            const r = Math.round(v);
            return (r < 0 ? '\u2212' + (-r) : String(r)) + ' °' + scope.units.temp;
          };
          scope.fmtPercent = function (x) { return Math.round((Number(x) || 0) * 100) + ' %'; };
          scope.fmtVolts = function (v) { return isFinite(Number(v)) && v !== undefined && v !== null ? Number(v).toFixed(1) + ' V' : ''; };
          scope.fmtTimes = function (v) { v = Number(v); return (v % 1 === 0 ? v.toFixed(0) : v.toFixed(2)) + 'x'; };

          scope.presetLabel = function () {
            const d = scope.data;
            if (d.enabled === false) return 'Off';
            const names = {arcade: 'Arcade', realistic: 'Realistic', brutal: 'Brutal'};
            return (names[d.preset] || 'Realistic') + (d.wearOn === false ? ' · no wear' : '');
          };
          scope.outsideSource = function () {
            return scope.hasOverride() ? 'set by you' : 'from level';
          };

          // Blue when freezing, through pale to amber when warm.
          scope.tempColor = function (c) {
            c = Number(c);
            if (!isFinite(c)) return '#9aa3b2';
            if (c <= -15) return '#58a6ff';
            if (c <= 0) return '#7cc4ff';
            if (c <= 15) return '#b9d9f2';
            if (c <= 60) return '#e6e9ef';
            if (c <= 105) return '#f5b544';
            return '#ef5350';
          };
          scope.warmth = function (c) {
            c = Number(c);
            if (!isFinite(c)) return 0;
            return Math.max(3, Math.min(100, (c + 40) / 130 * 100));
          };
          scope.batteryColor = function (x) {
            if (!scope.data.hasEngine) return '#9aa3b2';
            x = Number(x) || 0;
            return x > 0.6 ? '#4cc38a' : x > 0.35 ? '#f5b544' : '#ef5350';
          };

          const RATING_COLORS = ['#4cc38a', '#a8d672', '#f5b544', '#ef5350', '#ef5350'];
          scope.startLabel = function () {
            const d = scope.data;
            if (!d.hasEngine) return 'no engine';
            if (d.enabled === false) return 'off';
            if (!d.active) return 'standby';
            if (d.phase === 'running') return 'running';
            if (d.phase === 'cranking') return 'cranking';
            if (d.phase === 'catching') return 'catching';
            return d.ratingLabel || '--';
          };
          scope.startColor = function () {
            const d = scope.data;
            if (!d.hasEngine || d.enabled === false || !d.active) return '#9aa3b2';
            if (d.phase === 'running') return '#4cc38a';
            if (d.phase === 'cranking') return '#f5b544';
            if (d.phase === 'catching') return '#a8d672';
            return RATING_COLORS[d.rating] || '#9aa3b2';
          };
          scope.startSub = function () {
            const d = scope.data;
            if (!d.hasEngine || !d.active || d.phase !== 'off') return d.phase === 'running' && d.rpm ? d.rpm + ' rpm' : '';
            return d.expected ? '~' + (d.expected < 10 ? d.expected.toFixed(1) : Math.round(d.expected)) + ' s of cranking' : '';
          };
          // While cranking the bar shows how fast the starter is turning the engine.
          scope.showCrankBar = function () {
            return scope.data.active && (scope.data.phase === 'cranking' || scope.data.phase === 'catching');
          };
          scope.crankBar = function () { return Math.max(3, Math.min(100, (Number(scope.data.crankSpeed) || 0) * 100)); };

          scope.hintText = function () {
            const d = scope.data;
            if (!d.hasEngine) return 'This vehicle has no combustion engine.';
            if (d.enabled === false) return 'Cold start simulation is turned off.';
            if (!d.active) return 'Standing by: AI is driving, or you have not driven this car.';
            return d.hint || '';
          };
          scope.hintTone = function () {
            const d = scope.data;
            return d.hasEngine && d.active && d.hint ? (d.hintTone || 'info') : 'info';
          };

          scope.$on('streamsUpdate', function (event, streams) {
            const d = streams && streams.coldStart;
            if (!d) return;
            scope.$evalAsync(function () { scope.data = d; });
          });

          scope.$on('ColdStartSettings', function (event, s) {
            scope.$evalAsync(function () {
              scope.settings = s || {};
              scope.loaded = true;
              const o = scope.settings.outsideOverride;
              scope.slider.outside = (o !== undefined && o !== null) ? o
                : Math.round(Number(scope.settings.levelTemp !== undefined && scope.settings.levelTemp !== null ? scope.settings.levelTemp : scope.data.outside) || 0);
              confirmed = {outsideOverride: scope.slider.outside, batteryDrain: Number(scope.settings.batteryDrain), chargeRate: Number(scope.settings.chargeRate)};
            });
          });

          scope.$on('$destroy', function () {
            Object.keys(sliderTimers).forEach(function (k) { clearTimeout(sliderTimers[k]); });
            StreamsManager.remove(streamNames);
          });

          lua('requestSettings()');
        }
      };
    }]);
}
