// test file
data {
  int N;
  array[N] real x;
}
parameters {
  real mu;
}
model {
  x ~ normal(mu, 1);
}
