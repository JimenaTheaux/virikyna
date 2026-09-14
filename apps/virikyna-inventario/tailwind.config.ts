import type { Config } from 'tailwindcss'

// Mismos tokens que apps/virikyna-local/tailwind.config.ts, tomados 1:1 de
// docs/08_estilos_y_diseno.md — una sola identidad visual entre Caja e Inventario móvil.
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}', '../../packages/shared/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        accent: '#3FB9B9',
        'accent-dark': '#237878',
        'accent-darker': '#163F3F',
        'accent-light': '#E3F5F5',
        'verde-agua': '#86CAC2',
        amarillo: '#F6F19D',
        rosa: '#ECABCE',
        celeste: '#73CAE9',
        violeta: '#B192C4',
        ink: '#24242B',
        'ink-soft': '#6B6570',
        bg: '#F7F6FA',
        surface: '#FFFFFF',
        line: '#E6E2EA',
        error: '#C0392B',
        success: '#4A6F6B',
      },
      fontFamily: {
        display: ['Quicksand', 'system-ui', 'sans-serif'],
        sans: ['"DM Sans"', 'system-ui', 'sans-serif'],
      },
      fontSize: {
        'display-total': ['52px', { lineHeight: '1', fontWeight: '700' }],
        'display-card': ['32px', { lineHeight: '1', fontWeight: '600' }],
        'headline-lg': ['30px', { lineHeight: '38px', fontWeight: '700' }],
        'headline-md': ['22px', { lineHeight: '28px', fontWeight: '700' }],
        'body-lg': ['18px', { lineHeight: '28px', fontWeight: '500' }],
        'body-md': ['16px', { lineHeight: '24px', fontWeight: '400' }],
        'label-bold': ['14px', { lineHeight: '20px', fontWeight: '700' }],
        'label-md': ['13px', { lineHeight: '18px', fontWeight: '500' }],
      },
      borderRadius: {
        DEFAULT: '12px',
        lg: '16px',
        full: '999px',
      },
      spacing: {
        'stack-sm': '8px',
        'stack-md': '16px',
        'stack-lg': '32px',
        'gutter-grid': '16px',
        'card-sm': '20px',
        card: '24px',
        // Alto de zona segura inferior (barra de gestos iOS/Android) para la bottom nav.
        'safe-bottom': 'env(safe-area-inset-bottom, 0px)',
      },
    },
  },
  plugins: [],
} satisfies Config
