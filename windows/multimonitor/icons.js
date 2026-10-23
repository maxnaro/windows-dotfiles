import React from 'https://esm.sh/react@18?dev';

// Local Lucide symbols share one size and stroke, independent of the text font.
export function Icon({ name, className = '', children }) {
  return React.createElement(
    'svg',
    {
      className: `icon ${className}`.trim(),
      viewBox: '0 0 24 24',
      'aria-hidden': true,
      focusable: 'false',
    },
    React.createElement('use', { href: `./resources/icons.svg#${name}` }),
    children,
  );
}

export function getNetworkIcon(network) {
  let name;
  switch (network.defaultInterface?.type) {
    case 'ethernet':
      name = 'ethernet-port';
      break;
    case 'proprietary_virtual':
      name = 'shield-check';
      break;
    case 'wifi': {
      const strength = network.defaultGateway?.signalStrength ?? 0;
      name = strength >= 80 ? 'wifi'
        : strength >= 65 ? 'wifi-high'
        : strength >= 40 ? 'wifi-low'
        : 'wifi-zero';
      break;
    }
    default:
      name = 'wifi-off';
  }
  return React.createElement(Icon, { name });
}

export function getBatteryIcon(battery) {
  if (battery.isCharging) {
    return React.createElement(Icon, { name: 'battery-charging' });
  }
  const charge = Number.isFinite(battery.chargePercent)
    ? Math.max(0, Math.min(100, battery.chargePercent))
    : 0;
  return React.createElement(
    Icon,
    { name: 'battery', className: charge <= 20 ? 'low-battery' : '' },
    React.createElement('rect', {
      x: 5, y: 9, width: 10 * charge / 100, height: 6, rx: 0.75,
      fill: 'currentColor', stroke: 'none',
    }),
  );
}

const weatherIcons = {
  clear_day: 'sun',
  clear_night: 'moon',
  cloudy_day: 'cloud-sun',
  cloudy_night: 'cloud-moon',
  light_rain_day: 'cloud-drizzle',
  light_rain_night: 'cloud-drizzle',
  heavy_rain_day: 'cloud-rain',
  heavy_rain_night: 'cloud-rain',
  snow_day: 'cloud-snow',
  snow_night: 'cloud-snow',
  thunder_day: 'cloud-lightning',
  thunder_night: 'cloud-lightning',
};

export function getWeatherIcon(weather) {
  return React.createElement(Icon, {
    name: weatherIcons[weather.status] ?? 'cloud',
  });
}
