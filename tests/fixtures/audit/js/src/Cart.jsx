import { useTranslation } from 'react-i18next';

export function Cart({ name, total }) {
  const { t } = useTranslation();
  return (
    <div>
      <h1>Your shopping cart</h1>
      <input placeholder="Search products" />
      <p>{t('cart.greeting') + name}</p>
      <p>{`${t('cart.total')}: ${total}`}</p>
      <span>{total.toFixed(2)}</span>
      <p>{t('cart.empty')}</p>
    </div>
  );
}
