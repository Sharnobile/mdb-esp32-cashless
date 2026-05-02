import { describe, it, expect } from 'vitest';
import { mount } from '@vue/test-utils';
import CellularHealthBadge from '../CellularHealthBadge.vue';

describe('CellularHealthBadge', () => {
  it('renders nothing when diagnostics is null', () => {
    const w = mount(CellularHealthBadge, { props: { diagnostics: null } });
    expect(w.html()).toBe('<!--v-if-->');
  });

  it('renders nothing when uplink is not cellular', () => {
    const w = mount(CellularHealthBadge, {
      props: { diagnostics: { cellular: { uplink: 'wifi' } } },
    });
    expect(w.html()).toBe('<!--v-if-->');
  });

  it('renders bars + operator + mode for cellular uplink', () => {
    const w = mount(CellularHealthBadge, {
      props: {
        diagnostics: {
          cellular: { uplink: 'cellular', op: 'Vodafone DE', mode: 'LTE-M', rssi: -78, ip: '10.0.0.1' },
        },
      },
    });
    expect(w.text()).toContain('Vodafone DE');
    expect(w.text()).toContain('LTE-M');
    expect(w.html()).toMatchSnapshot();
  });

  it.each([
    [-50, 4],
    [-65, 4],
    [-66, 3],
    [-80, 3],
    [-81, 2],
    [-95, 2],
    [-96, 1],
    [-105, 1],
    [-106, 0],
  ])('dBm %d → %d bars', (dbm, expected) => {
    const w = mount(CellularHealthBadge, {
      props: { diagnostics: { cellular: { uplink: 'cellular', rssi: dbm } } },
    });
    const lit = w.findAll('span.bg-lime-400').length;
    expect(lit).toBe(expected);
  });
});
