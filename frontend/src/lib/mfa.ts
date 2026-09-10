import { supabase } from "./supabaseClient";

export async function obtenerFactorTotpVerificado() {
  const { data, error } = await supabase.auth.mfa.listFactors();
  if (error || !data) return null;
  return data.totp.find((factor) => factor.status === "verified") ?? null;
}

export async function verificarTotp(factorId: string, codigo: string) {
  const { data: challenge, error: errorChallenge } = await supabase.auth.mfa.challenge({
    factorId,
  });
  if (errorChallenge || !challenge) {
    return { error: errorChallenge ?? new Error("No se pudo iniciar la verificación.") };
  }
  const { error: errorVerify } = await supabase.auth.mfa.verify({
    factorId,
    challengeId: challenge.id,
    code: codigo,
  });
  return { error: errorVerify };
}
