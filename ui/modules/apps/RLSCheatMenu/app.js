// RLS Career Cheat Menu - UI app for RLS Career Overhaul.
// The Lua side lives in lua/ge/extensions/rlsCheatMenu.lua; this directive only sends commands
// through bngApi.engineLua and renders the state Lua pushes back on the "RLSCheatMenuState" hook.
'use strict';

{
  // Only plain identifiers ever reach Lua as strings (attribute keys, org ids), so strip anything else.
  const luaStr = function (value) {
    return '"' + String(value == null ? '' : value).replace(/[^A-Za-z0-9_\-.]/g, '') + '"';
  };
  const luaNum = function (value) {
    const n = Number(value);
    return isFinite(n) ? String(n) : 'nil';
  };
  // Load the extension on demand in case modScript has not run yet (or Lua was reloaded).
  const call = function (expr) {
    if (!window.bngApi || !window.bngApi.engineLua) return;
    window.bngApi.engineLua(
      'if not rlsCheatMenu then extensions.load("rlsCheatMenu") end; if rlsCheatMenu then rlsCheatMenu.' + expr + ' end'
    );
  };

  const template =
    '<div class="rlscm bngApp">' +
      '<link type="text/css" rel="stylesheet" href="/ui/modules/apps/RLSCheatMenu/app.css">' +
      '<div class="rlscm-header">' +
        '<span class="rlscm-title">RLS Cheat Menu</span>' +
        '<span class="rlscm-money" ng-if="s.active">{{ fmtMoney(s.money) }}</span>' +
        '<button class="rlscm-icon" ng-click="refresh()" title="Refresh">&#x21bb;</button>' +
      '</div>' +

      '<div class="rlscm-inactive" ng-if="!s.active">' +
        '<p>No RLS career is active.</p>' +
        '<p class="rlscm-dim">Load an RLS Career Overhaul save, then press refresh. Vehicle and world cheats still work.</p>' +
      '</div>' +

      '<div class="rlscm-tabs">' +
        '<button ng-repeat="t in tabs" ng-class="{active: tab === t.id}" ng-click="setTab(t.id)">{{ t.label }}</button>' +
      '</div>' +

      '<div class="rlscm-body">' +

        // Money --------------------------------------------------------------------------------
        '<div ng-if="tab === \'money\'">' +
          '<div class="rlscm-note" ng-if="s.cheatsMode">Freeroam+ cheats mode is on: RLS keeps money at $1T.</div>' +
          '<div class="rlscm-section">Money <span class="rlscm-dim">{{ fmtMoney(s.money) }}</span></div>' +
          '<div class="rlscm-row">' +
            '<button ng-repeat="p in moneyPresets" ng-click="addMoney(p)">+{{ fmtShort(p) }}</button>' +
          '</div>' +
          '<div class="rlscm-row">' +
            '<input type="number" ng-model="inputs.money" placeholder="Amount">' +
            '<button ng-click="addMoney(inputs.money)">Add</button>' +
            '<button ng-click="addMoney(-inputs.money)">Remove</button>' +
            '<button ng-click="setMoney(inputs.money)">Set</button>' +
          '</div>' +
          '<div class="rlscm-section">BeamXP <span class="rlscm-dim">{{ fmtNum(s.beamXP) }}</span></div>' +
          '<div class="rlscm-row">' +
            '<button ng-click="addAttr(\'beamXP\', 1000)">+1K</button>' +
            '<button ng-click="addAttr(\'beamXP\', 10000)">+10K</button>' +
            '<input type="number" ng-model="inputs.xp" placeholder="Amount">' +
            '<button ng-click="addAttr(\'beamXP\', inputs.xp)">Add</button>' +
          '</div>' +
          '<div class="rlscm-section">Vouchers <span class="rlscm-dim">{{ fmtNum(s.vouchers) }}</span></div>' +
          '<div class="rlscm-row">' +
            '<button ng-click="addAttr(\'vouchers\', 1)">+1</button>' +
            '<button ng-click="addAttr(\'vouchers\', 10)">+10</button>' +
            '<input type="number" ng-model="inputs.vouchers" placeholder="Amount">' +
            '<button ng-click="addAttr(\'vouchers\', inputs.vouchers)">Add</button>' +
          '</div>' +
          '<div class="rlscm-section">Loans <span class="rlscm-dim">{{ s.activeLoans || 0 }} active</span></div>' +
          '<div class="rlscm-row">' +
            '<button class="rlscm-warn" ng-click="confirmCall(\'clearLoans()\')">{{ armed === \'clearLoans()\' ? \'Click again to confirm\' : \'Clear all loans\' }}</button>' +
          '</div>' +
        '</div>' +

        // Skills -------------------------------------------------------------------------------
        '<div ng-if="tab === \'skills\'">' +
          '<div class="rlscm-row"><button class="rlscm-accent" ng-click="cmd(\'maxAllSkills()\')">Max all skills</button></div>' +
          '<div class="rlscm-empty" ng-if="!s.skills.length">No skills found.</div>' +
          '<div class="rlscm-item" ng-repeat="sk in s.skills track by sk.key">' +
            '<div class="rlscm-item-head">' +
              '<span>{{ sk.name }}</span>' +
              '<span class="rlscm-dim">Lv {{ sk.level }} / {{ sk.maxLevel }}</span>' +
            '</div>' +
            '<div class="rlscm-bar"><div ng-style="{width: (sk.maxLevel ? sk.level / sk.maxLevel * 100 : 0) + \'%\'}"></div></div>' +
            '<div class="rlscm-row">' +
              '<button ng-click="setSkill(sk, sk.level - 1)" ng-disabled="sk.level <= 0">-1</button>' +
              '<button ng-click="setSkill(sk, sk.level + 1)" ng-disabled="sk.level >= sk.maxLevel">+1</button>' +
              '<button ng-click="setSkill(sk, sk.maxLevel)" ng-disabled="sk.level >= sk.maxLevel">Max</button>' +
              '<button ng-click="setSkill(sk, 0)">Reset</button>' +
            '</div>' +
          '</div>' +
        '</div>' +

        // Reputation ---------------------------------------------------------------------------
        '<div ng-if="tab === \'rep\'">' +
          '<div class="rlscm-row">' +
            '<button class="rlscm-accent" ng-click="cmd(\'maxAllOrgReputation()\')">Max all organizations</button>' +
          '</div>' +
          '<div class="rlscm-section" ng-if="s.carMeetRep !== undefined">Car meet reputation ' +
            '<span class="rlscm-dim">{{ fmtNum(s.carMeetRep) }} / {{ fmtNum(s.carMeetRepMax) }}</span></div>' +
          '<div class="rlscm-row" ng-if="s.carMeetRep !== undefined">' +
            '<button ng-click="cmd(\'maxCarMeetReputation()\')">Max car meet rep</button>' +
          '</div>' +
          '<div class="rlscm-section">Organizations</div>' +
          '<div class="rlscm-empty" ng-if="!s.orgs.length">No organizations on this map.</div>' +
          '<div class="rlscm-item" ng-repeat="o in s.orgs track by o.id">' +
            '<div class="rlscm-item-head"><span>{{ o.name }}</span><span class="rlscm-dim">{{ fmtNum(o.value) }} / {{ o.max }}</span></div>' +
            '<div class="rlscm-row">' +
              '<button ng-click="setRep(o, o.value - 10)">-10</button>' +
              '<button ng-click="setRep(o, o.value + 10)">+10</button>' +
              '<button ng-click="setRep(o, \'max\')">Max</button>' +
              '<button ng-click="setRep(o, 0)">Zero</button>' +
            '</div>' +
          '</div>' +
        '</div>' +

        // Vehicle ------------------------------------------------------------------------------
        '<div ng-if="tab === \'vehicle\'">' +
          '<div class="rlscm-section">Current vehicle <span class="rlscm-dim">{{ s.ownedVehicle ? "owned" : "not owned / none" }}</span></div>' +
          '<div class="rlscm-grid">' +
            '<button ng-click="cmd(\'repairVehicle()\')">Free repair</button>' +
            '<button ng-click="cmd(\'refuel()\')">Refuel / recharge</button>' +
            '<button ng-click="cmd(\'serviceVehicle()\')">Reset wear and tires</button>' +
          '</div>' +
          '<div class="rlscm-section">Police <span class="rlscm-dim" ng-class="{\'rlscm-hot\': s.inPursuit}">{{ s.inPursuit ? "IN PURSUIT" : "clear" }}</span></div>' +
          '<div class="rlscm-row"><button ng-click="cmd(\'clearWanted()\')">End pursuit</button></div>' +
          '<div class="rlscm-section">Insurance driver score <span class="rlscm-dim">{{ s.driverScore }}</span></div>' +
          '<div class="rlscm-row">' +
            '<button ng-click="setScore(64)">Default (64)</button>' +
            '<button ng-click="setScore(100)">Perfect (100)</button>' +
            '<input type="number" ng-model="inputs.score" placeholder="Score">' +
            '<button ng-click="setScore(inputs.score)">Set</button>' +
          '</div>' +
        '</div>' +

        // World --------------------------------------------------------------------------------
        '<div ng-if="tab === \'world\'">' +
          '<div class="rlscm-section">Time of day <span class="rlscm-dim">{{ fmtTime(s.timeOfDay) }}</span></div>' +
          '<div class="rlscm-row">' +
            '<button ng-click="setHour(6)">Dawn</button>' +
            '<button ng-click="setHour(12)">Noon</button>' +
            '<button ng-click="setHour(18)">Dusk</button>' +
            '<button ng-click="setHour(0)">Midnight</button>' +
          '</div>' +
          '<div class="rlscm-dim rlscm-small">RLS weather may move time on by itself afterwards.</div>' +
          '<div class="rlscm-section">Career</div>' +
          '<div class="rlscm-row"><button class="rlscm-accent" ng-click="cmd(\'saveCareer()\')">Save career now</button></div>' +
        '</div>' +

      '</div>' +
    '</div>';

  angular.module('beamng.apps')
    .directive('rlsCheatMenu', [function () {
      return {
        template: template,
        replace: true,
        restrict: 'EA',
        link: function (scope) {
          scope.s = {active: false, skills: [], orgs: []};
          scope.inputs = {};
          scope.tabs = [
            {id: 'money', label: 'Money'},
            {id: 'skills', label: 'Skills'},
            {id: 'rep', label: 'Rep'},
            {id: 'vehicle', label: 'Vehicle'},
            {id: 'world', label: 'World'}
          ];
          scope.moneyPresets = [1000, 10000, 100000, 1000000];

          let savedTab = 'money';
          try { savedTab = localStorage.getItem('rlsCheatMenu.tab') || 'money'; } catch (e) {}
          scope.tab = savedTab;
          scope.setTab = function (id) {
            scope.tab = id;
            try { localStorage.setItem('rlsCheatMenu.tab', id); } catch (e) {}
          };

          scope.cmd = call;
          scope.refresh = function () { call('requestState()'); };
          // Two-click confirm: in-game CEF does not reliably show window.confirm dialogs.
          let armTimer = null;
          scope.confirmCall = function (expr) {
            if (scope.armed === expr) {
              scope.armed = null;
              call(expr);
              return;
            }
            scope.armed = expr;
            clearTimeout(armTimer);
            armTimer = setTimeout(function () { scope.$evalAsync(function () { scope.armed = null; }); }, 3000);
          };

          scope.addMoney = function (n) { if (Number(n)) call('addMoney(' + luaNum(n) + ')'); };
          scope.setMoney = function (n) {
            if (n === undefined || n === null || n === '') return;
            call('setMoney(' + luaNum(n) + ')');
          };
          scope.addAttr = function (key, n) { if (Number(n)) call('addAttribute(' + luaStr(key) + ', ' + luaNum(n) + ')'); };
          scope.setSkill = function (sk, level) {
            level = Math.max(0, Math.min(sk.maxLevel, level));
            call('setSkillLevel(' + luaStr(sk.key) + ', ' + luaNum(level) + ')');
          };
          scope.setRep = function (org, value) {
            const v = value === 'max' ? '"max"' : luaNum(value);
            call('setOrgReputation(' + luaStr(org.id) + ', ' + v + ')');
          };
          scope.setScore = function (n) {
            if (n === undefined || n === null || n === '') return;
            call('setDriverScore(' + luaNum(n) + ')');
          };
          // BeamNG time of day: 0 = noon, 0.5 = midnight.
          scope.setHour = function (h) { call('setTimeOfDay(' + luaNum(((h - 12) / 24 + 1) % 1) + ')'); };

          scope.fmtNum = function (n) {
            n = Number(n) || 0;
            return Math.round(n).toLocaleString('en-US');
          };
          scope.fmtMoney = function (n) {
            n = Number(n) || 0;
            return (n < 0 ? '-$' : '$') + Math.abs(n).toLocaleString('en-US', {maximumFractionDigits: 2});
          };
          scope.fmtShort = function (n) {
            if (n >= 1e6) return (n / 1e6) + 'M';
            if (n >= 1e3) return (n / 1e3) + 'K';
            return String(n);
          };
          scope.fmtTime = function (t) {
            if (t === undefined || t === null) return '--:--';
            const minutes = Math.round((((Number(t) * 24) + 12) % 24) * 60);
            const hh = Math.floor(minutes / 60) % 24, mm = minutes % 60;
            return (hh < 10 ? '0' : '') + hh + ':' + (mm < 10 ? '0' : '') + mm;
          };

          scope.$on('RLSCheatMenuState', function (event, data) {
            scope.$evalAsync(function () {
              const s = data || {};
              s.skills = Array.isArray(s.skills) ? s.skills : [];
              s.orgs = Array.isArray(s.orgs) ? s.orgs : [];
              scope.s = s;
            });
          });

          call('setUiOpen(true)');
          scope.$on('$destroy', function () { call('setUiOpen(false)'); });
        }
      };
    }]);
}
