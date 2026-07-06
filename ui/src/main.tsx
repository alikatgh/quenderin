
import ReactDOM from 'react-dom/client'
// Q-568: self-host the fonts. An offline/privacy-first app must not fetch Inter + JetBrains Mono from
// Google on every load (an IP/timing leak + a hard network dependency). These bundle the variable fonts
// into the build; the Google <link>s are removed from index.html and the CSP tightened accordingly.
import '@fontsource-variable/inter'
import '@fontsource-variable/jetbrains-mono'
import App from './App.js'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')!).render(
    <App />
)
