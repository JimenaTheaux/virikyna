import type { Config } from 'tailwindcss'

// Tokens tomados 1:1 de docs/08_estilos_y_diseno.md — no agregar valores que no estén
// documentados ahí. Ver ese archivo como fuente de verdad si hace falta ajustar algo.
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}', '../../packages/shared/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        // Primario — teal (sección 2), extraído de la versión color del wordmark
        accent: '#3FB9B9',
        'accent-dark': '#237878',
        'accent-darker': '#163F3F',
        'accent-light': '#E3F5F5',
        // Paleta secundaria — uso puntual, no dominante
        'verde-agua': '#86CAC2',
        amarillo: '#F6F19D',
        rosa: '#ECABCE',
        celeste: '#73CAE9',
        violeta: '#B192C4',
        // Neutros y semánticos
        ink: '#24242B',
        'ink-soft': '#6B6570',
        bg: '#F7F6FA',
        surface: '#FFFFFF',
        line: '#E6E2EA',
        error: '#C0392B',
        success: '#4A6F6B',
      },
      fontFamily: {
        // Títulos, totales, números protagonistas
        display: ['Quicksand', 'system-ui', 'sans-serif'],
        // Texto de UI, tablas, formularios, botones
        sans: ['"DM Sans"', 'system-ui', 'sans-serif'],
      },
      // Escala tipográfica (sección 3) — cada token trae tamaño, interlineado y peso
      // documentados; la fuente (display/sans) se aplica aparte según la tabla del doc.
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
      // Espaciado y forma (sección 4)
      borderRadius: {
        DEFAULT: '12px', // radius-default → rounded
        lg: '16px', // radius-lg → rounded-lg
        full: '999px', // radius-full → rounded-full
      },
      spacing: {
        'stack-sm': '8px',
        'stack-md': '16px',
        'stack-lg': '32px',
        'gutter-grid': '16px',
        'card-sm': '20px',
        card: '24px',
      },
    },
  },
  plugins: [],
} satisfies Config
