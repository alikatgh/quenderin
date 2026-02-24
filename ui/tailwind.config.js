/** @type {import('tailwindcss').Config} */
export default {
  darkMode: 'class',
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter', '-apple-system', 'BlinkMacSystemFont', 'Segoe UI', 'Roboto', 'Helvetica', 'Arial', 'sans-serif'],
        mono: ['SFMono-Regular', 'Menlo', 'Monaco', 'Consolas', 'Liberation Mono', 'Courier New', 'monospace'],
      },
      colors: {
        background: '#09090b', // zinc-950 but slightly darker
        surface: '#18181b',    // zinc-900
        border: '#27272a',     // zinc-800
        primary: '#fafafa',    // zinc-50
        muted: '#a1a1aa',      // zinc-400
      },
      animation: {
        'pulse-slow': 'pulse 3s cubic-bezier(0.4, 0, 0.6, 1) infinite',
        'fade-in': 'fadeIn 0.5s ease-out forwards',
      },
      keyframes: {
        fadeIn: {
          '0%': { opacity: '0', transform: 'translateY(5px)' },
          '100%': { opacity: '1', transform: 'translateY(0)' },
        }
      },
      typography: (theme) => ({
        DEFAULT: {
          css: {
            color: theme('colors.zinc.800'),
            maxWidth: '100%',
            a: {
              color: theme('colors.blue.600'),
              textDecoration: 'none',
              fontWeight: '500',
              '&:hover': {
                color: theme('colors.blue.700'),
                textDecoration: 'underline',
              },
            },
            h1: { color: theme('colors.zinc.900'), fontWeight: '700' },
            h2: { color: theme('colors.zinc.900'), fontWeight: '600', marginTop: '1.5em' },
            h3: { color: theme('colors.zinc.900'), fontWeight: '600' },
            strong: { color: theme('colors.zinc.900'), fontWeight: '600' },
            code: {
              color: theme('colors.zinc.800'),
              backgroundColor: theme('colors.zinc.100'),
              padding: '0.2em 0.4em',
              borderRadius: '6px',
              fontWeight: '500',
              fontFamily: theme('fontFamily.mono').join(', '),
              fontSize: '0.875em',
            },
            'code::before': { content: 'none' },
            'code::after': { content: 'none' },
            pre: {
              backgroundColor: theme('colors.zinc.900'),
              color: theme('colors.zinc.100'),
              borderRadius: 'rem',
              padding: '1rem',
              overflowX: 'auto',
              border: `1px solid ${theme('colors.zinc.200')}`,
              code: {
                backgroundColor: 'transparent',
                color: 'inherit',
                padding: '0',
                border: 'none',
              }
            },
            blockquote: {
              borderLeftColor: theme('colors.zinc.300'),
              color: theme('colors.zinc.600'),
              fontStyle: 'normal',
            },
          },
        },
        invert: {
          css: {
            color: theme('colors.zinc.300'),
            a: {
              color: theme('colors.blue.400'),
              '&:hover': { color: theme('colors.blue.300') },
            },
            h1: { color: theme('colors.zinc.100') },
            h2: { color: theme('colors.zinc.100') },
            h3: { color: theme('colors.zinc.100') },
            strong: { color: theme('colors.zinc.100') },
            code: {
              color: theme('colors.zinc.200'),
              backgroundColor: theme('colors.zinc.800'),
            },
            pre: {
              backgroundColor: '#18181b', // Exact surface mapping
              border: `1px solid ${theme('colors.zinc.800')}`,
            },
            blockquote: {
              borderLeftColor: theme('colors.zinc.700'),
              color: theme('colors.zinc.400'),
            },
            hr: { borderColor: theme('colors.zinc.800') },
            thead: {
              borderBottomColor: theme('colors.zinc.700'),
              th: { color: theme('colors.zinc.200') },
            },
            tbody: {
              tr: { borderBottomColor: theme('colors.zinc.800') },
            },
          },
        },
      }),
    },
  },
  plugins: [
    require('@tailwindcss/typography'),
  ],
}
