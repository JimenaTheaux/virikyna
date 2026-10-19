// Sesión activa sin perfil admin (cajero, o usuario desactivado) se resuelve en AuthContext con
// signOut automático — acá solo falta la sesión, nunca sobra el rol.
export { RequireAuth } from './AuthContext'
