import { createContext, useContext, type ReactNode } from "react";
import styles from "./privacy-mask.module.css";

export const PrivacyMask = createContext(false);

export function usePrivacyMask() {
  return useContext(PrivacyMask);
}

export function PrivateName({ children }: { children: ReactNode }) {
  const masked = usePrivacyMask();
  return masked ? (
    <span className={styles.mask} role="img" aria-label="已隐藏" />
  ) : (
    children
  );
}
