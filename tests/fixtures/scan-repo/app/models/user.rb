class User
  def label(n)
    I18n.t("users.count", count: n)
  end
end
