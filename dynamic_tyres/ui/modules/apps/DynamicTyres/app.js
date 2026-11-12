// Dynamic Tyres - live tyre app and settings.
// Wheel data arrives on the "dynamicTyres" vehicle stream; settings on the "DynamicTyresSettings" hook.
'use strict';

{
  const PSI_KPA = 6.894757;

  const lua = function (expr) {
    if (!window.bngApi || !window.bngApi.engineLua) return;
    window.bngApi.engineLua(
      'if not dynamicTyresManager then extensions.load("dynamicTyresManager") end; if dynamicTyresManager then dynamicTyresManager.' + expr + ' end'
    );
  };
  const luaValue = function (v) {
    if (v === true || v === false) return String(v);
    if (v === null || v === undefined || v === '') return 'nil';
    if (typeof v === 'number') return isFinite(v) ? String(v) : 'nil';
    return '"' + String(v).replace(/[^A-Za-z0-9_\-.]/g, '') + '"';
  };

  const store = {
    get: function (k, d) { try { const v = localStorage.getItem('dynamicTyres.' + k); return v === null ? d : v; } catch (e) { return d; } },
    set: function (k, v) { try { localStorage.setItem('dynamicTyres.' + k, v); } catch (e) {} }
  };

  // Order wheels front to rear, left to right, from names like FL, RR, RL2, ML.
  const wheelPlace = function (name) {
    const n = String(name || '').toUpperCase();
    const axleChar = n.charAt(0);
    const num = Number((n.match(/(\d+)/) || [0, 0])[1]);
    const axle = axleChar === 'F' ? 0 : axleChar === 'M' ? 40 + num : axleChar === 'R' ? 80 + num : 60 + num;
    const last = n.replace(/\d+/g, '').slice(-1);
    const side = last === 'L' ? 'L' : last === 'R' && n.length > 1 ? 'R' : 'C';
    return {axle: axle, side: side};
  };

  const template =
    '<div class="dyt bngApp">' +
      '<link type="text/css" rel="stylesheet" href="/ui/modules/apps/DynamicTyres/app.css">' +
      '<div class="dyt-header">' +
        '<span class="dyt-title">Dynamic Tyres</span>' +
        '<span class="dyt-chip" title="Ambient temperature">{{ fmtTemp(data.ambient) }}</span>' +
        '<span class="dyt-chip" ng-class="roadClass(data)" title="Road condition">{{ roadLabel(data) }}</span>' +
        '<button class="dyt-icon" ng-class="{active: view === \'details\'}" ng-click="setView(view === \'details\' ? \'wheels\' : \'details\')" title="Grip breakdown">&#x2261;</button>' +
        '<button class="dyt-icon" ng-class="{active: view === \'settings\'}" ng-click="setView(view === \'settings\' ? \'wheels\' : \'settings\')" title="Settings">&#x2699;</button>' +
      '</div>' +

      '<div class="dyt-banner" ng-if="data.yieldedTo && view !== \'settings\'">Tyres on this vehicle are run by {{ data.yieldedTo }}. Dynamic Tyres is standing by.</div>' +
      '<div class="dyt-banner" ng-if="data.enabled === false && view !== \'settings\'">Dynamic Tyres is turned off. Turn it on in settings.</div>' +
      '<div class="dyt-empty" ng-if="!data.wheels.length && view !== \'settings\'">Waiting for vehicle data&hellip;</div>' +

      // Wheels / details --------------------------------------------------------------------------
      '<div class="dyt-body" ng-if="view !== \'settings\'">' +
        '<div class="dyt-axle" ng-repeat="axle in axles track by axle.key">' +
          '<div class="dyt-wheel" ng-repeat="w in axle.wheels track by w.name" ng-class="{\'dyt-flat\': w.flat}">' +
            '<div class="dyt-wheel-head">' +
              '<b>{{ w.name }}</b><span class="dyt-dim">{{ w.compound }}<span ng-if="w.compoundForced" title="Chosen in settings">*</span></span>' +
              '<span class="dyt-grip" ng-style="{color: gripColor(w.grip)}">{{ (w.grip * 100).toFixed(0) }}%</span>' +
            '</div>' +
            '<div class="dyt-zones">' +
              '<div class="dyt-zone" ng-repeat="z in w.zoneView track by $index" ng-style="{background: tempColor(z.t, w.optTemp)}" title="{{ z.label }}">' +
                '<span>{{ fmtTempShort(z.t) }}</span>' +
              '</div>' +
            '</div>' +
            '<div ng-if="view === \'wheels\'">' +
              '<div class="dyt-line"><span>Core</span><span>{{ fmtTemp(w.core) }}</span></div>' +
              '<div class="dyt-line"><span>Pressure</span><span ng-class="{\'dyt-dim\': !w.realPressure}">{{ fmtPressure(w.pressure) }}</span></div>' +
              '<div class="dyt-line"><span>Tread</span><span ng-style="{color: treadColor(w.tread)}">{{ (w.tread * 100).toFixed(w.tread < 0.1 ? 1 : 0) }}%</span></div>' +
              '<div class="dyt-tread"><div ng-style="{width: (w.tread * 100) + \'%\', background: treadColor(w.tread)}"></div></div>' +
            '</div>' +
            '<div ng-if="view === \'details\'" class="dyt-factors">' +
              '<div class="dyt-line" ng-repeat="f in factorList track by f.key"><span>{{ f.label }}</span><span ng-style="{color: factorColor(w.factors[f.key])}">{{ fmtFactor(w.factors[f.key]) }}</span></div>' +
              '<div class="dyt-line"><span>Surface</span><span>{{ w.surface }}</span></div>' +
              '<div class="dyt-line"><span>Distance</span><span>{{ w.distance }} km</span></div>' +
              '<div class="dyt-line" ng-if="w.heatCycles"><span>Heat cycles</span><span>{{ w.heatCycles }}</span></div>' +
            '</div>' +
            '<div class="dyt-badges">' +
              '<span class="dyt-badge dyt-bad" ng-if="w.flat">{{ w.flatReason || "FLAT" }}</span>' +
              '<span class="dyt-badge dyt-bad" ng-if="w.aquaplane > 0.5">AQUAPLANING</span>' +
              '<span class="dyt-badge dyt-warn" ng-if="w.aquaplane > 0.1 && w.aquaplane <= 0.5">aquaplaning</span>' +
              '<span class="dyt-badge dyt-ice" ng-if="w.ice > 0.1">ICE</span>' +
              '<span class="dyt-badge dyt-snow" ng-if="w.snow > 0.1">SNOW</span>' +
              '<span class="dyt-badge dyt-warn" ng-if="w.flatSpot > 0.15">flat spot {{ (w.flatSpot * 100).toFixed(0) }}%</span>' +
              '<span class="dyt-badge dyt-warn" ng-if="w.tread < 0.1 && !w.flat">CORDS</span>' +
            '</div>' +
          '</div>' +
        '</div>' +
      '</div>' +

      // Settings ---------------------------------------------------------------------------------
      // Rendered only once the settings have arrived: a range input without a value snaps to its
      // midpoint and would write that back as if the user had moved it.
      '<div class="dyt-body dyt-settings" ng-if="view === \'settings\' && loaded">' +
        '<div class="dyt-section">Simulation</div>' +
        '<label class="dyt-toggle" ng-repeat="t in toggles track by t.key">' +
          '<input type="checkbox" ng-model="settings[t.key]" ng-change="set(t.key, settings[t.key])">' +
          '<span>{{ t.label }}</span><small>{{ t.hint }}</small>' +
        '</label>' +

        '<div class="dyt-section">Strength</div>' +
        '<div class="dyt-slider" ng-repeat="sl in sliders track by sl.key">' +
          '<span>{{ sl.label }}</span>' +
          '<input type="range" min="{{ sl.min }}" max="{{ sl.max }}" step="{{ sl.step }}" ng-model="settings[sl.key]" ng-change="setLater(sl.key, settings[sl.key])">' +
          '<b>{{ fmtSlider(sl, settings[sl.key]) }}</b>' +
        '</div>' +

        '<div class="dyt-section">Road <span class="dyt-dim">now {{ roadLabel({wetness: settings.currentWetness, snow: settings.currentSnow, ice: settings.currentIce}) }}' +
          '<span ng-if="settings.rainIntensity > 0.02">, raining</span><span ng-if="settings.snowIntensity > 0.02">, snowing</span></span></div>' +
        '<div class="dyt-row">' +
          '<button ng-repeat="m in wetModes" ng-class="{active: settings.wetMode === m.id}" ng-click="set(\'wetMode\', m.id)">{{ m.label }}</button>' +
        '</div>' +
        '<div class="dyt-dim dyt-small" ng-if="settings.wetMode === \'auto\'">Auto follows the weather: rain wets the road, snow settles below 2&deg;C, wet roads freeze below 0&deg;C and thaw above it.</div>' +

        '<div class="dyt-section">Snowfall</div>' +
        '<div class="dyt-row">' +
          '<button ng-repeat="m in snowModes" ng-class="{active: settings.snowfall === m.id}" ng-click="set(\'snowfall\', m.id)">{{ m.label }}</button>' +
        '</div>' +
        '<div class="dyt-dim dyt-small" ng-if="settings.snowfall !== \'off\'">Snowing keeps it below freezing unless you pick an ambient temperature.' +
          '<span ng-if="!settings.snowEffectAvailable"> This level has no snow effect, so no flakes, but snow still settles on the road.</span></div>' +

        '<div class="dyt-section">Ambient temperature <span class="dyt-dim">{{ fmtTemp(settings.currentAmbient) }}</span></div>' +
        '<div class="dyt-row">' +
          '<button ng-class="{active: settings.ambientOverride === undefined || settings.ambientOverride === null}" ng-click="set(\'ambientOverride\', null)">From level</button>' +
          '<button ng-repeat="a in ambientPresets" ng-class="{active: settings.ambientOverride === a}" ng-click="set(\'ambientOverride\', a)">{{ fmtTemp(a) }}</button>' +
        '</div>' +

        '<div class="dyt-section">Current vehicle</div>' +
        '<div class="dyt-row dyt-compound">' +
          '<span>Front tyres</span><select ng-model="compoundPick.front" ng-change="setCompound(\'front\', compoundPick.front)" ng-options="c.id as c.label for c in compoundOptions"></select>' +
        '</div>' +
        '<div class="dyt-row dyt-compound">' +
          '<span>Rear tyres</span><select ng-model="compoundPick.rear" ng-change="setCompound(\'rear\', compoundPick.rear)" ng-options="c.id as c.label for c in compoundOptions"></select>' +
        '</div>' +
        '<div class="dyt-dim dyt-small">Changing type fits a new set on that axle. Auto uses the type of the fitted tyre part.</div>' +
        '<div class="dyt-row">' +
          '<button ng-click="vehicleCall(\'fitNewTyres\')">Fit new tyres</button>' +
          '<button ng-click="vehicleCall(\'warmTyres\')">Tyre warmers</button>' +
        '</div>' +
        '<div class="dyt-row dyt-pressure">' +
          '<span>Front</span><button ng-click="pressure(\'front\', -1)">&minus;</button><button ng-click="pressure(\'front\', 1)">+</button>' +
          '<span>Rear</span><button ng-click="pressure(\'rear\', -1)">&minus;</button><button ng-click="pressure(\'rear\', 1)">+</button>' +
          '<button ng-click="vehicleCall(\'resetColdPressure\')">Stock</button>' +
        '</div>' +
        '<div class="dyt-dim dyt-small">Pressure steps are 1 psi (7 kPa) of cold pressure.</div>' +

        '<div class="dyt-section">Units</div>' +
        '<div class="dyt-row">' +
          '<button ng-class="{active: units.temp === \'C\'}" ng-click="setUnit(\'temp\', \'C\')">&deg;C</button>' +
          '<button ng-class="{active: units.temp === \'F\'}" ng-click="setUnit(\'temp\', \'F\')">&deg;F</button>' +
          '<button ng-class="{active: units.pressure === \'psi\'}" ng-click="setUnit(\'pressure\', \'psi\')">psi</button>' +
          '<button ng-class="{active: units.pressure === \'kPa\'}" ng-click="setUnit(\'pressure\', \'kPa\')">kPa</button>' +
          '<button ng-class="{active: units.pressure === \'bar\'}" ng-click="setUnit(\'pressure\', \'bar\')">bar</button>' +
        '</div>' +
        '<div class="dyt-row"><button class="dyt-warn-btn" ng-click="resetSettings()">Reset all settings</button></div>' +
      '</div>' +
    '</div>';

  angular.module('beamng.apps')
    .directive('dynamicTyres', [function () {
      return {
        template: template,
        replace: true,
        restrict: 'EA',
        link: function (scope) {
          const streamNames = ['dynamicTyres'];
          StreamsManager.add(streamNames);

          scope.data = {wheels: []};
          scope.axles = [];
          scope.settings = {};
          scope.loaded = false;
          scope.view = store.get('view', 'wheels');
          scope.units = {temp: store.get('tempUnit', 'C'), pressure: store.get('pressureUnit', 'psi')};

          scope.toggles = [
            {key: 'enabled', label: 'Dynamic tyres', hint: 'master switch'},
            {key: 'temperature', label: 'Temperature', hint: 'heat, cooling, grip window'},
            {key: 'wear', label: 'Wear', hint: 'tread loss, worn grip'},
            {key: 'pressure', label: 'Pressure', hint: 'hot pressure, contact patch'},
            {key: 'applyPressure', label: 'Pressure affects physics', hint: 'pushes pressure to the tyre'},
            {key: 'surface', label: 'Surface and wet', hint: 'compound vs surface, rain, aquaplaning'},
            {key: 'extras', label: 'Extras', hint: 'scrub-in, heat cycles, flat spots'},
            {key: 'punctures', label: 'Punctures and blowouts', hint: 'worn-through and overheated tyres'},
            {key: 'aiVehicles', label: 'AI and traffic too', hint: 'off = only the car you drive'},
            {key: 'resetWearOnReset', label: 'New tyres on vehicle reset', hint: 'reset repairs the car'}
          ];
          scope.sliders = [
            {key: 'gripStrength', label: 'Grip effect', min: 0, max: 1.5, step: 0.05, pct: true},
            {key: 'heatRate', label: 'Heat rate', min: 0.25, max: 3, step: 0.05},
            {key: 'wearRate', label: 'Wear rate', min: 0, max: 20, step: 0.5}
          ];
          scope.wetModes = [
            {id: 'auto', label: 'Auto (weather)'}, {id: 'dry', label: 'Dry'}, {id: 'damp', label: 'Damp'},
            {id: 'wet', label: 'Wet'}, {id: 'soaked', label: 'Soaked'}, {id: 'snow', label: 'Snow'},
            {id: 'ice', label: 'Ice'}, {id: 'blackIce', label: 'Black ice'}
          ];
          scope.snowModes = [{id: 'off', label: 'Off'}, {id: 'light', label: 'Light'}, {id: 'heavy', label: 'Heavy'}];
          scope.compoundOptions = [
            {id: 'auto', label: 'Auto (from part)'}, {id: 'slick', label: 'Slick'}, {id: 'sport', label: 'Sport'},
            {id: 'road', label: 'Road'}, {id: 'allTerrain', label: 'All-terrain'}, {id: 'mud', label: 'Mud-terrain'},
            {id: 'winter', label: 'Winter'}
          ];
          scope.compoundPick = {front: 'auto', rear: 'auto'};
          scope.setCompound = function (axle, id) {
            lua('playerVehicleCall("setCompound", ' + luaValue(axle) + ', ' + luaValue(id) + ')');
          };
          scope.ambientPresets = [0, 10, 20, 30, 40];
          scope.factorList = [
            {key: 'temperature', label: 'Temperature'}, {key: 'wear', label: 'Wear'},
            {key: 'pressure', label: 'Pressure'}, {key: 'surface', label: 'Surface'},
            {key: 'wet', label: 'Wet'}, {key: 'snowIce', label: 'Snow / ice'}, {key: 'extras', label: 'Extras'}
          ];

          scope.setView = function (v) {
            scope.view = v;
            store.set('view', v);
            if (v === 'settings') lua('requestSettings()');
          };
          scope.setUnit = function (kind, unit) {
            scope.units[kind] = unit;
            store.set(kind === 'temp' ? 'tempUnit' : 'pressureUnit', unit);
          };

          scope.set = function (key, value) { lua('setSetting(' + luaValue(key) + ', ' + luaValue(value) + ')'); };
          // Sliders fire on every pixel; only send the last value.
          let sliderTimer = null;
          scope.setLater = function (key, value) {
            clearTimeout(sliderTimer);
            sliderTimer = setTimeout(function () { scope.set(key, Number(value)); }, 250);
          };
          scope.resetSettings = function () { lua('resetSettings()'); };
          scope.vehicleCall = function (fn) { lua('playerVehicleCall(' + luaValue(fn) + ')'); };
          scope.pressure = function (axle, dir) {
            lua('playerVehicleCall("adjustColdPressure", ' + luaValue(axle) + ', ' + (dir * PSI_KPA).toFixed(3) + ')');
          };

          // Formatting -------------------------------------------------------------------------
          const toUnitTemp = function (c) { return scope.units.temp === 'F' ? c * 9 / 5 + 32 : c; };
          scope.fmtTemp = function (c) {
            if (c === undefined || c === null) return '--';
            return Math.round(toUnitTemp(Number(c))) + '°' + scope.units.temp;
          };
          scope.fmtTempShort = function (c) { return Math.round(toUnitTemp(Number(c) || 0)) + '°'; };
          scope.fmtPressure = function (kpa) {
            kpa = Number(kpa) || 0;
            if (scope.units.pressure === 'kPa') return kpa.toFixed(0) + ' kPa';
            if (scope.units.pressure === 'bar') return (kpa / 100).toFixed(2) + ' bar';
            return (kpa / PSI_KPA).toFixed(1) + ' psi';
          };
          scope.fmtFactor = function (f) {
            f = Number(f);
            if (!isFinite(f)) return '--';
            const pct = Math.round((f - 1) * 1000) / 10;
            return (pct > 0 ? '+' : '') + pct.toFixed(1) + '%';
          };
          scope.fmtSlider = function (sl, v) {
            v = Number(v);
            return sl.pct ? Math.round(v * 100) + '%' : v.toFixed(sl.step < 0.1 ? 2 : 1) + 'x';
          };
          scope.wetLabel = function (w) {
            w = Number(w) || 0;
            if (w < 0.05) return 'Dry';
            if (w < 0.4) return 'Damp ' + Math.round(w * 100) + '%';
            if (w < 0.8) return 'Wet ' + Math.round(w * 100) + '%';
            return 'Soaked';
          };

          scope.roadLabel = function (d) {
            d = d || {};
            const ice = Number(d.ice) || 0, snow = Number(d.snow) || 0;
            if (ice >= 0.05 && ice >= snow) return 'Ice ' + Math.round(ice * 100) + '%';
            if (snow >= 0.05) return 'Snow ' + Math.round(snow * 100) + '%';
            return scope.wetLabel(d.wetness);
          };
          scope.roadClass = function (d) {
            d = d || {};
            if ((Number(d.ice) || 0) >= 0.05 && (Number(d.ice) || 0) >= (Number(d.snow) || 0)) return 'dyt-chip-ice';
            if ((Number(d.snow) || 0) >= 0.05) return 'dyt-chip-snow';
            return (Number(d.wetness) || 0) > 0.05 ? 'dyt-chip-wet' : '';
          };

          // Colours ----------------------------------------------------------------------------
          // Blue when cold, green in the window, red when overheated.
          scope.tempColor = function (t, opt) {
            const x = Math.max(-1, Math.min(1.6, ((Number(t) || 0) - (Number(opt) || 60)) / 40));
            const hue = x < 0 ? 130 + (-x) * 80 : Math.max(0, 130 - x * 130);
            return 'hsl(' + hue.toFixed(0) + ', 70%, ' + (x > 1 ? 42 : 38) + '%)';
          };
          scope.treadColor = function (t) {
            t = Number(t) || 0;
            return t > 0.5 ? '#4cc38a' : t > 0.2 ? '#f5b544' : '#ef5350';
          };
          scope.gripColor = function (g) {
            g = Number(g) || 1;
            return g >= 0.98 ? '#4cc38a' : g >= 0.88 ? '#f5b544' : '#ef5350';
          };
          scope.factorColor = function (f) {
            f = Number(f);
            return f >= 0.995 ? '#4cc38a' : f >= 0.93 ? '#f5b544' : '#ef5350';
          };

          // Outer shoulder on the outside of the car: left wheels read outer|mid|inner.
          // Built once per update: ng-repeat must not get fresh objects on every digest.
          const zoneOrder = function (w) {
            const z = w.zones || [0, 0, 0];
            const inner = {t: z[0], label: 'Inner'}, mid = {t: z[1], label: 'Middle'}, outer = {t: z[2], label: 'Outer'};
            return w.place && w.place.side === 'L' ? [outer, mid, inner] : [inner, mid, outer];
          };

          const groupAxles = function (wheels) {
            const byAxle = {};
            wheels.forEach(function (w) {
              w.place = wheelPlace(w.name);
              w.zoneView = zoneOrder(w);
              (byAxle[w.place.axle] = byAxle[w.place.axle] || []).push(w);
            });
            return Object.keys(byAxle).map(Number).sort(function (a, b) { return a - b; }).map(function (k) {
              const list = byAxle[k].sort(function (a, b) {
                const rank = {L: 0, C: 1, R: 2};
                return rank[a.place.side] - rank[b.place.side] || (a.name < b.name ? -1 : 1);
              });
              return {key: String(k), wheels: list};
            });
          };

          scope.$on('streamsUpdate', function (event, streams) {
            const d = streams && streams.dynamicTyres;
            if (!d) return;
            scope.$evalAsync(function () {
              d.wheels = Array.isArray(d.wheels) ? d.wheels : [];
              scope.data = d;
              scope.axles = groupAxles(d.wheels);
            });
          });

          scope.$on('DynamicTyresSettings', function (event, s) {
            scope.$evalAsync(function () {
              scope.settings = s || {};
              scope.loaded = true;
              const pc = scope.settings.playerCompounds || {};
              scope.compoundPick = {front: pc.front || 'auto', rear: pc.rear || 'auto'};
            });
          });

          scope.$on('$destroy', function () {
            clearTimeout(sliderTimer);
            StreamsManager.remove(streamNames);
          });

          lua('requestSettings()');
        }
      };
    }]);
}
